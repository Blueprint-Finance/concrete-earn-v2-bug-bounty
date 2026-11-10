# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.7.1] - 2026-09-29

Package-only re-publish of `1.7.0`; no Solidity source changes between `1.7.0` and `1.7.1`. Contract IDs stay at `1.7.0`.

### Changed

- **Hook `IContractId.ID()` values updated to `1.7.0`** (hook `VERSION()` literals, now covered by `scripts/bump-version-diff.js`): `HookContainer` `500110700`, `UserDepositCapHook` `500210700`, `WhitelistUserDepositHook` `500310700`, `DepositLockHook` `500410700`, `DepositLockWithFeeHook` `500510700`, `DepositLockRegSHook` `500610700`, `MultiAssetDepositCapHook` `500910700`. The `PeripheryFactory` hook registry keys off `ID()`, so hook implementations must be re-registered under the new IDs.

## [1.7.0] - 2026-09-29

Headline addition versus 1.6: the **multi-asset deposit async vault** (`ConcreteMultiAssetDepositAsyncVault`), which accepts whitelisted non-base tokens, values them in base units through a pluggable **asset pricer** (`OneToOneAssetPricer`, `OracleAssetPricer` backed by a new Chainlink **`OracleModule`**), and routes them straight to a **`MultiAssetStrategy`**. Also adds the `PRE_MULTI_DEPOSIT` hook point with a per-token `MultiAssetDepositCapHook`, oracle-module timelock coverage, and the Earn v1.7 audit remediations. Vault and hook `IContractId.ID()` values bump to `1.7.0`. Published to npm as `@concrete-xyz/earn-v2-core@1.7.0`. Full notes: `doc/releases/v1.7.0.md`.

### Added

- **`ConcreteMultiAssetDepositAsyncVault`** (`src/implementation/`, `FLAVOUR() = 8`): async vault variant with a `deposit(address depositAsset, uint256 assets, address receiver)` / `previewDeposit(address, uint256)` overload. Base-asset deposits use the inherited ERC-4626 flow; whitelisted non-base deposits are priced to base value, mint shares, and are pushed straight to the configured Active strategy via `IMultiAssetDepositStrategy.allocateFundsMultiAsset` (reverts `BaseAllocatedMismatch` unless the strategy books exactly the priced value). `cachedTotalAssets` and the strategy `allocated` are credited in base units. Admin via `configureMultiAsset(MultiAssetVaultManagerConfig, bytes)` (`AddWhitelistedAsset`, `SetPricer`, `SetMultiAssetStrategy`; VAULT_MANAGER, TIER_2) and an instant `removeWhitelistedAsset`. Views: `isWhitelistedAsset`, `getWhitelistedAssets`, `getMultiAssetPricer`, `getMultiAssetStrategy`. Flow lives in the DELEGATECALL library `MultiAssetVaultHelperLib`; storage in the EIP-7201 namespace `concrete.storage.ConcreteMultiAssetDepositAsyncVaultStorage`.
- **`MultiAssetStrategy`** (`src/periphery/strategies/`, `FLAVOUR() = 8`) and **`IMultiAssetDepositStrategy`**: `MultisigStrategy` that additionally implements `allocateFundsMultiAsset`, forwarding the raw non-base token to the multisig while booking the vault-supplied base value in `vaultDepositedAmount`. New `ZeroMultiAssetAllocation` error and `AllocateFundsMultiAsset` event.
- **Asset pricers** (`IAssetPricer`, `src/pricer/`): `OneToOneAssetPricer` (decimal-adjusted 1:1, for same-peg assets) and `OracleAssetPricer` (two-legged `price(deposit) / price(base)` from an `OracleModule`, single `mulDiv`, rounds down).
- **`OracleModule`** (`src/periphery/oracle/`): Chainlink feed registry with per-asset price bounds and staleness checks, module-wide feed `decimals`, an optional L2 sequencer uptime gate with grace period (`setSequencerOracle`), `Ownable2Step` ownership with `renounceOwnership` disabled, and timelock integration (`setOracle` / `setSequencerOracle` / `transferOwnership` TIER_2, `setTimelock` TIER_1; `removeOracle` instant).
- **`PRE_MULTI_DEPOSIT` hook** (`HooksLibV2` flag `13`, `IHook.preMultiDeposit`): raised only on non-base deposits, carrying the raw token and amount alongside the base value and shares. No-op default in `BaseHook`; `HookContainer` forwards it to sub-hooks.
- **`MultiAssetDepositCapHook`** (`src/periphery/hooks/`, `FLAVOUR() = 9`): lifetime per-token deposit cap in the token's own decimals on the `PRE_MULTI_DEPOSIT` point. Offset-by-one cap encoding (`0` = uncapped), monotonic rolling sum that also tracks uncapped tokens, caller gated to the vault or a same-vault `HookContainer`.
- **Timelock contract type `CT_ORACLE_MODULE`** and a `CT_VAULT` artifact for `configureMultiAsset` (TIER_2) in `TimelockConfigurationLib` / `TimelockContractTypesLib`.
- **`StateSetterMASLib`** (`src/lib/StateSetterMASLib.sol`): New library wrapping the two strategy-registry lifecycle setters that delete a strategy, so the multi-asset non-base deposit pointer (`MASLib.strategy`) follows the lifecycle of the strategy it names. `removeStrategy` clears the pointer to `address(0)` (removal is terminal); `reconcileHaltedStrategy` moves it onto `toStrategy` (already validated registered + `Active` by the inner call), or clears it on the `address(0)` loss write-off branch. Each wrapper delegates the registry work to `StateSetterLib` rather than reimplementing it, so the two cannot drift. Previously the pointer was written only by `setMultiAssetStrategy` (VAULT_MANAGER, TIER_2 timelocked) while the registry was mutated by STRATEGY_MANAGER, so removing or reconciling the designated strategy left the pointer dangling: every non-base `deposit` / `previewDeposit` reverted `MultiAssetStrategyNotActive` while base-asset deposits kept working, and re-adding the same address later silently re-armed the stale pointer with no VAULT_MANAGER re-designation.

### Changed

- **`IContractId.ID()` bump to `1.7.0`** on vault implementations (`ConcreteStandardVaultImpl` `110700`, `ConcreteAsyncVaultImpl` `210700`, `ConcretePredepositVaultImpl` `310700`, `ConcreteBridgedStandardVaultImpl` `510700`, `ConcreteBridgedAsyncVaultImpl` `610700`, new `ConcreteMultiAssetDepositAsyncVault` `810700`), the new `MultiAssetStrategy` (`200810700`), and hooks (`HookContainer` `500110700`, `UserDepositCapHook` `500210700`, `WhitelistUserDepositHook` `500310700`, `DepositLockHook` `500410700`, `DepositLockWithFeeHook` `500510700`, `DepositLockRegSHook` `500610700`, new `MultiAssetDepositCapHook` `500910700`). `SimpleStrategy`, `MultisigStrategy`, `ConcreteStandardLoopingStrategy` and the position helpers are unchanged and stay at `1.6.0`. Implementations must be re-registered against the new IDs.
- **`Timelock.reinitializeV2()` → `reinitializeV3()`** (`reinitializer(3)`, `UPGRADER_ROLE`): re-seeds all artifact registries, now including `CT_ORACLE_MODULE`. Deployed timelocks call it via `upgradeToAndCall`.
- **`ConcreteStandardVaultImpl._deposit` / `_withdraw` moved to `UserActionsLib.executeDeposit` / `executeWithdraw`** (DELEGATECALL) to free runtime bytecode; transfer / mint / burn ordering is unchanged.
- **Minimum deposit check moved into `UserActionsLib.preDeposit` / `preMint`** so it applies to base and non-base deposits alike. `MinimumDepositAmountNotMet` is now raised before `ERC4626ExceededMaxDeposit` / `ERC4626ExceededMaxMint`.
- **`ConcreteMultiAssetDepositAsyncVault` overrides `removeStrategy` / `reconcileHaltedStrategy`** to route through `StateSetterMASLib` instead of `StateSetterLib`. The overrides deliberately do not call `super` — the overlay replaces the base implementation — so the vault's runtime bytecode is unchanged (24,495 B, 81 B of EIP-170 margin). Plain (non-multi-asset) vaults are untouched and keep calling `StateSetterLib` directly. `toggleStrategyStatus` is deliberately not wrapped: a halt is reversible and instant, so halt → unhalt still self-heals rather than requiring a 24h `configureMultiAsset` repair.
- **`scripts/bump-version-diff.js`**: also bumps hook `VERSION()` literals, and treats a change in any library (or file-level free function / constant) a contract uses, transitively, as a reason to bump it.

### Fixed

- **`maxMint`** returns `0` when the floor/ceil round-trip of the remaining deposit capacity falls below `minTxDepositAmount`, and **`maxRedeem`** returns `0` when the redeemable shares convert to fewer assets than `minTxWithdrawAmount`, so neither view advertises an amount the action would reject.

### Security (audit remediations)

- **FIND-002**: Owner-gated `OracleModule` controls could be stranded by a mistyped timelocked ownership transfer — `OracleModule` now uses `Ownable2Step`; ownership moves only on `acceptOwnership`.
- **FIND-004**: Obscured price-check enforcement — `OracleSet` now carries `validateCaps` and `validateStaleness`, so a config with checks disabled is distinguishable from an enforced one.
- **FIND-006**: Non-base deposits blocked by an unsynchronized multi-asset strategy pointer — fixed via `StateSetterMASLib` (see Added / Changed).
- **FIND-007**: Missing standard `Deposit` event on the non-base path — `IERC4626.Deposit` is now emitted alongside `MultiAssetDeposit`.
- **FIND-009**: Non-base deposit hook semantics — documented that `PRE_DEPOSIT` / `POST_DEPOSIT` fire on non-base deposits too (with a base-equivalent `assets` notional) and that `PRE_MULTI_DEPOSIT` is exclusive to them (`IHook` NatSpec, `doc/Architecture.md`). No logic change.

## [1.6.0]

Headline additions versus 1.5: **Dolomite** as a Position Management Helper venue, **timelock coverage** for `HookContainer` and AssetCX liquidation, and an `IContractId.ID()` bump to `1.6.0` on vaults, strategies, and existing PMHs. The hook base-class / factory-bound clone work landed as `[1.5.1-Beta]` and is included in this line (hook `VERSION()` / `ID()` remain `1.5.1`).

### Added

- **Dolomite Position Management Helper** (`src/periphery/positionhelper/`): Dolomite as a lending venue alongside Aave V3 and Morpho.
  - `PositionHelperDolomiteBase`: shared supply / withdraw / borrow / repay primitives, position / LTV / margin views, market-ID resolution, and Dolomite sub-account transfers. Positions are `operate` bundles on `IDolomiteMargin` keyed by `{ owner, number }`.
  - `PositionHelperDolomiteNative` (`ID()` `400310600`): self-liquidates via a Dolomite-whitelisted exchange wrapper (`Sell` action, no flash loan); falls back to the flash-loan + swap-module path when no wrapper is set.
  - `PositionHelperDolomiteAssetCX` (`ID()` `400410600`): AssetCX collateral flavour; delegates self-liquidation to a `liquidationModule` gated by `LIQUIDATOR_ROLE`. `selfLiquidateToLtv` is disabled (`SelfLiquidateToLtvDisabled`) because the module takes an explicit debt amount.
  - Libraries: `DolomiteAccountActionLib` (builds / executes `operate` action bundles), `DolomitePositionViewLib`, `PositionHelperDolomiteStorageLib`, `PositionHelperDolomiteAssetCXStorageLib`.
  - Interfaces: `IDolomiteMargin`, `ILiquidationModule`.
- **Timelock artifact seeding for new contract types** (`TimelockConfigurationLib`, `TimelockContractTypesLib`, `ITimelockGatedSelectors`):
  - `CT_HOOK_CONTAINER` — `addHook` / `replaceHook` (TIER_2), `setTimelock` (TIER_1); `removeHook` stays instant by design.
  - `CT_ASSETCX_LIQUIDATION_MODULE` — `setCollateralRatio` / `setBuffer` / `unpause` (TIER_3) and `LIQUIDATOR_ROLE` (TIER_2).
  - `CT_REDEMPTION_CLAIM_TOKEN` — whitelist / pause surface for the AssetCX claim token.
- **`Timelock.reinitializeV2()`**: `reinitializer(2)` / `UPGRADER_ROLE` entry point that re-runs artifact-registry seeding so an already-deployed timelock picks up the new contract types and selectors (typically via `upgradeToAndCall`). Idempotent; does not touch schedules, bindings, roles, or `active`.

### Changed

- **`IContractId.ID()` bump to `1.6.0`** on vault implementations (`ConcreteStandardVaultImpl` `110600`, `ConcreteAsyncVaultImpl` `210600`, `ConcretePredepositVaultImpl` `310600`, `ConcreteBridgedStandardVaultImpl` `510600`, `ConcreteBridgedAsyncVaultImpl` `610600`), strategies (`SimpleStrategy` `200110600`, `MultisigStrategy` `200210600`, `ConcreteStandardLoopingStrategy` `200310600`), and existing position helpers (`PositionHelperAaveV3` `400110600`, `PositionHelperMorpho` `400210600`). Factory registration and upgrade paths key off `ID()`, so implementations must be re-registered against the new IDs. Hook `ID()` values stay at `1.5.1` (see `[1.5.1-Beta]`).
- **`PeripheryFactory.clonePMH` immutable args**: `_getImmutableArgs` still writes the 62-byte header `[positionOwner][collateralToken][borrowToken][decimals×2]`. If the implementation exposes `resolveTokenInfo(address)` (Dolomite flavours), the two market IDs are appended (62 → 126 bytes). Other PMH flavours are unchanged.
- **`HookContainer` timelock integration**: `addHook`, `replaceHook`, `setTimelock`, and `grantRole` are `afterDelay`-gated via `TimelockIntegrationLib`. Bind the container as `CT_HOOK_CONTAINER` on the timelock before activating enforcement.
- **`PositionHelperBase` / Aave / Morpho / `LoopingPrimitiveLib`**: shared-surface alignment for the Dolomite flavours (no independent behaviour change).

### Fixed

- **CONC-4105 — `Timelock.checkDelayExpired`**: only a *bound* protected contract (`contractTypeOf[msg.sender] != 0`) may consume a schedule entry, so an unbound caller cannot replay a matured `actionId`.
- **Dolomite default account may hold debt**: the default sub-account is allowed to carry debt (Dolomite position helper).

## [1.5.1-Beta]

### Added

- **`BaseHook`** (`src/periphery/hooks/BaseHook.sol`): New abstract base for every vault hook. Centralizes the boilerplate shared across all hooks: the `VAULT()` / `FACTORY()` immutable-args accessors, the `_disableInitializers()` constructor, the `__BaseHook_init()` clone-initializer guard (factory-only), the shared `NotFactory` / `ZeroAddress` errors, the `CONTRACT_TYPE = 5` constant, and the `FLAVOUR()` / `VERSION()` / `ID()` identity scaffolding. Also provides no-op `external virtual` defaults for all ten `IHook` entry points so concrete hooks only override the lifecycle points they implement. Carries no mutable storage and no access-control mixin (left to subclasses).
- **`BaseOwnableHook`** (`src/periphery/hooks/BaseOwnableHook.sol`): New abstract base layering `OwnableUpgradeable` on top of `BaseHook` for owner-managed validator hooks, exposing a shared `__BaseOwnableHook_init(owner)` initializer that chains the factory guard and `__Ownable_init`.
- **`IHook.FACTORY()`**: New interface method exposing the factory authorized to initialize a hook clone (alongside the existing `VAULT()`).

### Changed

- **Hooks deployed with `[factory (20)][vault (20)]` immutable args**: Hook clones now embed both the deploying factory and the bound vault as ClonesWithImmutableArgs immutable args (previously hooks carried no immutable args and received the vault through `initData`). `PeripheryFactory.cloneHook` now takes a `vault_` parameter — `cloneHook(uint64 implId, address vault_, bytes initData)` — and appends `abi.encodePacked(address(this), vault_)` to the clone bytecode. Each hook's `initialize(...)` is now gated to the embedded factory (`NotFactory`), closing the clone-initialization front-running window: only the factory baked into the clone can initialize it, and that initialization happens atomically within the `cloneHook` call.
- **Hooks refactored onto `BaseHook` / `BaseOwnableHook`**: `HookContainer` now inherits `BaseHook` + `AccessControlDefaultAdminRulesEnumerableUpgradeable`; `UserDepositCapHook`, `DepositLockHook`, and the `DepositLockHook` derivatives (`DepositLockWithFeeHook`, `DepositLockRegSHook`) inherit `BaseOwnableHook`; `WhitelistUserDepositHook` continues to extend `UserDepositCapHook`. The duplicated immutable-args accessors, `_disableInitializers` constructor, factory guard, `CONTRACT_TYPE`, `ID()` computation, common errors, and redundant no-op `IHook` implementations were removed from each hook. Per-hook identity is now expressed via `FLAVOUR()` and `VERSION()`, with `ID()` composed in `BaseHook`. No behavioural change to hook enforcement logic.
- **Hook `IContractId.ID()` bump to `1.5.1`** (from `1.5.0`): `HookContainer` (`500110501`), `UserDepositCapHook` (`500210501`), `WhitelistUserDepositHook` (`500310501`), `DepositLockHook` (`500410501`), `DepositLockWithFeeHook` (`500510501`), `DepositLockRegSHook` (`500610501`). The `PeripheryFactory` hook registry keys off `ID()`, so implementations registered under the old IDs must be re-registered under the new ones.
- **`PeripheryFactory.renounceOwnership`**: marked `view` (compiler-warning cleanup; behaviour unchanged — still reverts with `RenounceOwnershipDisabled`).

## [1.5.0]

> Target release: **1.5.0**. This section aggregates everything landing in the 1.5.0 line
> (currently shipped as `1.5.0-beta-*` pre-releases). The headline additions are the on-chain
> **Timelock** governance layer and a clonable **Hooks** system, plus a batch of audit remediations.

### Added

- **Timelock governance layer** (`src/periphery/timelock/Timelock.sol`, `ITimelock`, `ITimelockGatedSelectors`, `src/interface/ITimelockProtected.sol`): a new on-chain, tier-based delay system that gates privileged actions across the protocol.
  - Core flow: `propose(target, selector, args)` → wait the tier delay → execute; `cancel(actionId)` (guardian); `updateTierDelay(tier, delay)`, `addArtifact(contractType, artifact, tier)`, `bindContract` / `unbindContract`, and `activateTimelock()`.
  - Per-selector tier configuration, tier-order invariant enforcement in `updateTierDelay`, expiring/stale `actionId` cleanup, and `computeID`/`checkExpired` helpers.
  - Roles split into `DEFAULT_ADMIN_ROLE`, `CONFIG_ROLE`, and `GUARDIAN_ROLE` (`TimelockRolesLib`); self-timelock so the timelock delays changes to its own config, with default admin retained on timelocked roles.
  - Integrated into `PeripheryFactory`, `ConcreteFactory`, `ConcreteStandardVaultImpl`, `ConcreteAsyncVaultImpl`, strategies, and hooks via `TimelockIntegrationLib`, `TimelockConfigurationLib`, `TimelockContractTypesLib`, and `TimelockStorageLib`.
  - Full spec in `doc/spec/Timelock.md`; extensive integration tests for factory, strategies, standard vault, and async vault.
- **Clonable Hooks system**: hooks are now clonable with immutable args (the bound `vault` is an immutable arg), carry an on-chain `ID()`, and can be registered/managed through the `PeripheryFactory`. `HookContainer` gains `replaceHook`, an `onlyVault` guard, and pause/role/delay controls on hook functions; pending hooks also carry an `ID`.
- **`DepositLockRegSHook`** (`src/periphery/hooks/DepositLockRegSHook.sol`, `IDepositLockRegSHook`): Reg S transfer-lock hook with its own spec (`doc/spec/DepositLockRegSHook.md`).
- **Halted strategy reconciliation** (`ConcreteStandardVaultImpl` / `StateSetterLib`): a single `STRATEGY_MANAGER`-only entry point to settle the frozen position of a Halted strategy before removal, so the derived floating amount stays exact (no phantom funds):
  - `reconcileHaltedStrategy(address fromStrategy, address toStrategy)` — when `toStrategy == address(0)` it writes `fromStrategy`'s `allocated` off `cachedTotalAssets` (socialized loss) and removes it (use when the position is unrecoverable and there is no successor); otherwise it moves the `allocated` onto an Active `toStrategy` and removes the Halted one, preserving `cachedTotalAssets` and the aggregate allocation (the next yield accrual on the destination reconciles any real shortfall as a loss, or none if fully recovered out of band). Emits `StrategyLossRealized` or `StrategyAllocationMigrated`, plus `StrategyRemoved`.
  - New errors `StrategyNotHalted` and `StrategyHasNoAllocation`; new events `StrategyLossRealized` and `StrategyAllocationMigrated`.
  - Intentionally callable while the vault is paused, since it is an incident-response tool for broken strategies (the loss write-down is also safer while paused, with no user operations racing the share-price change). The migrate branch raises the destination's `allocated` (cost basis) by the migrated amount, so recovered principal is never booked as yield/performance fee. Documented in `doc/spec/HaltedStrategyHandling.md`.
- **Donation sweeper** (`ConcreteStandardVaultImpl.sweepDonatedTokens(address token, address recipient)` / `WithdrawLib.sweepDonatedTokens`): sweeps donated surplus, whether it is the underlying asset (surplus over the derived floating amount) or any other token sitting in the vault.
- **Two-step ownership transfer** on `ConcreteFactory` and `PeripheryFactory` (plus a two-step `propose`/`accept` for `setMultiSig` and two-step ownership on the async vault). New unit tests for `2stepOwnershipTransfer()`.
- **Pausability** added to `ConcreteFactory` and `PeripheryFactory` (and additional functions guarded by a pause modifier), plus a `FACTORY_MANAGER` role, factory artifact management, an `authoriseUpgrade` event on `ConcreteFactory`, and a method/role to remove stale `actionId`s.
- **Position Management Helper — LTV-range management**: `setHealthyLtvInWad`, `setHealthyLtvDeviationInWad`, and `setSelfLiqThrBufferInWad` setters (with matching `healthyLtvInWad` / `healthyLtvDeviationInWad` / `selfLiqThrBufferInWad` views), all `POSITION_ADMIN_ROLE`-gated and validated via `_ltvRangeIsValid`.
- **New libraries**: `ERC4626Lib`, `UserActionsLib`, `TimelockIntegrationLib`, and the timelock lib family listed above.
- **Release tooling**: `scripts/bump-version-diff.js` (bumps `ContractIdEncoding` IDs for every contract whose own file *or any ancestor* changed since a reference tag, using solc's `linearizedBaseContracts`) with the `.github/workflows/bump_version.yml` and `.github/workflows/publish_npm.yml` workflows (the latter resolves the npm dist-tag — `alpha`/`beta`/`latest` — from the `package.json` version).

### Changed

- **`IContractId.ID()` bump to `1.5.0`** across all vault implementations (`ConcreteStandardVaultImpl`, `ConcreteAsyncVaultImpl`, `ConcreteBridgedStandardVaultImpl`, `ConcreteBridgedAsyncVaultImpl`, `ConcretePredepositVaultImpl`), strategies (`SimpleStrategy`, `MultisigStrategy`, `ConcreteStandardLoopingStrategy`), hooks (`HookContainer`, `UserDepositCapHook`, `WhitelistUserDepositHook`, `DepositLockHook`, `DepositLockWithFeeHook`, `DepositLockRegSHook`), and position helpers (`PositionHelperAaveV3`, `PositionHelperMorpho`). `FLAVOUR` is now a virtual function on the versioned contracts. Factory registration and upgrade paths key off `ID()`, so implementations must be re-registered against the new IDs.
- **Solidity pragma bumped to `^0.8.27`** across the contracts.
- **Donation accounting now uses a derived floating amount**: removed the stored `floating` and `tracksFloatingAmount` slots from `ConcreteCachedVaultStateStorage`. The floating amount is derived on demand as `cachedTotalAssets - SUM(strategy.allocated) + lockedAssets` (`StandardVaultHelperLib.floatingAmount`), which is immune to donations and removes the per-operation bookkeeping and upgrade/migration logic the stored variable required. Over-allocation is now rejected with an explicit `cachedTotalAssets >= SUM(strategy.allocated)` guard in `allocate`, and `sweepDonatedTokens` computes the donated surplus from the derived value. Removed `MigrationLib.setFloatingAmount` and its initialization flag.
- **`removeStrategy` no longer accepts Halted strategies with an outstanding allocation**: a strategy can only be removed once `allocated == 0` and it is out of the deallocation order. Halted strategies that still hold a position must first be reconciled via `reconcileHaltedStrategy`. This prevents dropping `allocated` without adjusting `cachedTotalAssets`, which would inflate the derived floating amount.
- **Refactor: logic extracted into libraries** for readability and to relieve contract-size / stack pressure — validation and setters into `StateSetterLib` (`addStrategy`, `setHooks`, unified `configure`), `_initialize` decode/validation into `StateInitLib`, epoch/queue and preview logic into `AsyncVaultHelperLib` / `StandardVaultHelperLib`, `getMaxWithdraw` into `BaseLoopingHelperLib`; several `ConversionLib` / `calcMax*` functions made `public`.
- **Timelock tier tuning**: merchant fund-flow moved from tier3 → tier2; vault/strategy `unpause` moved from tier2 → tier3 and given an explicit delay; extra timelock configuration for AssetCX.
- **Gas / build**: `getUserEpochRequestInAssets` optimized, `_accrueYield` wrapper inlined into call sites, and optimizer runs reduced.

### Fixed

- **Partial epoch processing**: floating-accounting fix for partial-epoch processing.
- **Failed flash operations can bypass their explicit failure signal**: failed flash operations now correctly propagate their failure signal.
- **Donation-induced underflow avoided**: `cachedTotalAssets` is updated as usual via `accrueYield`, sidestepping a hypothetical donation-attack underflow.

### Security (audit remediations)

- **FIND-001**: Missing timelock artifacts could strand role rotation and unpause — fixed.
- **FIND-003 (CONC-3911)**: Operator could set a zero self-liquidation buffer, disabling preemptive liquidation — now rejected.
- **FIND-008 (CONC-3925)**: Hook clones could be mis-initialized through an inherited base function — fixed.
- **FIND-040 (CONC-3927)**: Holders could unlock Reg S transfer-locked shares and redirect them to third parties — fixed.
- **FIND-041**: Disabling looping now resets the LTV bounds and skips the lender-LTV check.
- **FIND-046 (CONC-3989)**: Vault managers could sweep shares backing queued withdrawals — `lockedAssets` is now passed through to `claimPriorityWithdrawal` / sweeping.
- **FIND-052 (CONC-4028)**: Invalid Morpho oracle values could disable position recovery — handled.
- **FIND-054**: Mixed Aave positions could distort automated recovery decisions — `getLiquidationThresholdInWad` now uses the account-wide threshold from `getUserAccountData`, and state-changing operations are gated by `onlySingleCollateralPosition` (single collateral / single debt reserve).
- **FIND-024**: Enforce a minimum cooldown period.
- **HAL-051 (CONC-4080)**: Timelock self-timelock hardening — default admin added to timelocked roles.
- **HAL-055**: Added a bound check in `_setMaxSlippage`.
- Additional hardening: hard absolute upper bound on `maxAccountingChangeThreshold`, `renounceRole` protection, and forgotten `actionId` protection.

## [1.4.1] - 2026-05-26

### Changed

- **Strategy `IContractId.ID()` bump to `1.4.1`**: `SimpleStrategy` (`200110401`), `MultisigStrategy` (`200210401`), and `ConcreteStandardLoopingStrategy` (`200310401`) — up from `1.1.0` (`200110100` / `200210100` / `200310100`). The IDs were stale: between v1.1.0 and v1.3.0, `BaseStrategy.__BaseStrategy_init` gained `_setRoleAdmin(PeripheryRolesLib.STRATEGY_UPGRADER, PeripheryRolesLib.ROLE_ADMIN)`, so strategies deployed before that change lack the correct `STRATEGY_UPGRADER` admin wiring. The bump lets the `PeripheryFactory` and off-chain tooling distinguish old deployments from new ones. No logic, interface, or storage changes.

## [1.4.0] - 2026-05-19

### Added

- **Partial epoch processing** (`ConcreteAsyncVaultImpl`): Individual withdrawal requests from a closed-but-unprocessed epoch can now be fulfilled on demand using idle vault liquidity, at the current exchange rate. New entry points:
  - `processPartialEpochRequest(address user, uint256 epochID, uint256 amount)` — burns the requested shares and transfers the equivalent assets from idle liquidity for a specific user/epoch pair. Restricted to `WITHDRAWAL_MANAGER`.
  - `moveRequestToNextEpoch(address user, uint256 fromEpochID, uint256 amount)` — transfers an outstanding request from a closed epoch to the next open epoch without settling it, so it can be processed in the normal epoch flow. Restricted to `WITHDRAWAL_MANAGER`.
  - New `PartialEpochRequestProcessed(address indexed user, uint256 epochID, uint256 shares, uint256 assets)` event.
  - New `EpochMismatch(uint256 providedEpochID, uint256 expectedEpochID)` error; shared validation between both entry points.
  - Shares are burned at the partial-processing timestamp and the request is cleared (or decremented, when partially processed).
- **`DepositLockHook`** (`src/periphery/hooks/DepositLockHook.sol`): New periphery hook that time-locks user deposits. Per-user locks are stored in a bounded array sorted by `unlockTimestamp`; on every withdraw the still-locked balance is checked against the requested amount (`LockedAmount` revert). Expired locks are cleaned lazily on subsequent operations. Admin can configure a base `lockDuration` via `setLockDuration` (`duration == 0` is rejected with `InvalidDuration`). Emits `LockCreated`, `LockDurationUpdated`, and `LocksCleanedUp`.
- **`DepositLockWithFeeHook`** (`src/periphery/hooks/DepositLockWithFeeHook.sol`): Extends `DepositLockHook` with an early-unlock path. Locks can be unwound before `unlockTimestamp` by paying a time-decaying fee to a configurable recipient. Fee decays linearly from `maxEarlyUnlockFee` at lock creation to `0` at `unlockTimestamp`. Locks shorter than `minLockPeriod` are rejected with `LockDurationTooShort`. Emits `EarlyUnlockFeeUpdated`, `MinLockPeriodUpdated`, `FeeRecipientUpdated`, and `EarlyUnlock`.
- **PRE/POST transfer hooks**:
  - New `PRE_TRANSFER = 11` and `POST_TRANSFER = 12` flags in `HooksLibV2`.
  - `IHook.preTransfer(address sender, address from, address to, uint256 shares)` and `IHook.postTransfer(...)` added to the hook interface. Both flagged hooks are dispatched only on genuine transfers (mints and burns bypass them — those paths already have dedicated hooks).
  - `ERC20UpgradeableWithTransferHook` (`src/common/ERC20UpgradeableWithTransferHook.sol`): New `ERC20Upgradeable` mixin that wires the transfer hooks into `_update`, reading hook configuration from `ConcreteStandardVaultImplStorageLib`.
- **Vault context on hooks**: `IHook.vault() returns (address)` added. `HookContainer` and every periphery hook now expose their bound vault; `HookContainer` is gated with a new `onlyVault` modifier plus `OnlyVault` and `HookVaultMismatch` errors. `HookContainer._removePrefix` helper added for cleaner sub-hook removal.
- **`UserDepositCapHook` — per-vault caps**: The hook now tracks caps per bound vault rather than globally. New `DepositCapSet(uint256 oldCap, uint256 newCap)` event.
- **Unified vault configuration entry point** (`ConcreteStandardVaultImpl`): New `configure(VaultManagerConfig configType, bytes calldata data)` restricted to `VAULT_MANAGER`. Dispatches through `StateSetterLib.configure` to the existing setters:
  - `ManagementFee` (`uint16`), `PerformanceFee` (`uint16`), `HurdleRateOracle` (`IHurdleRateOracle`), `DepositLimits` (`uint256 minTx, uint256 maxGlobal`), `WithdrawLimits` (`uint256 minTx, uint256 maxTx`).
  - New `VaultManagerConfig` enum and `InvalidVaultManagerConfig` error.
- **`MaxStalenessTooHigh(uint256 value, uint256 max)`** error on `OffchainHurdleRateOracle` — enforces a finite upper bound on `setMaxStaleness`.
- **Specification documents**:
  - `doc/spec/PartialEpochProcessing.md` — full spec for the partial epoch processing flow (flow diagrams, invariants, interaction with `processEpoch()`, edge cases).
  - `doc/spec/DepositLockHooks.md` — full spec for `DepositLockHook` and `DepositLockWithFeeHook` (storage model, sorted insertion, cleanup semantics, enforcement paths, fee decay model, invariants).
  - `doc/spec/ConcreteAsyncVaultImpl.md` updated with partial-epoch functions and related state.

### Changed

- **`IContractId.ID()` version bump** (`710a85f`): The on-chain `ID()` of the five vault implementations is bumped to `1.4.0` (`ContractIdEncoding` suffix `0400`). Affected contracts and new IDs: `ConcreteStandardVaultImpl` (`110400`), `ConcreteAsyncVaultImpl` (`210400`), `ConcreteBridgedStandardVaultImpl` (`510400`), `ConcreteBridgedAsyncVaultImpl` (`610400`), `ConcretePredepositVaultImpl` (`310400`). Factory registration and upgrade paths key off `ID()`, so deployments of these implementations from a `ConcreteFactory` registered against the old IDs must re-register against the new ones.
- **Hook interface — breaking**: `HooksLibV1` renamed to `HooksLibV2`; flag constants preserved and extended with `PRE_TRANSFER` / `POST_TRANSFER`. Hook signatures now carry both sides of the conversion:
  - `preDeposit(sender, assets, shares, receiver, totalAssets)` (previously `(sender, assets, receiver, totalAssets)`).
  - `preMint(sender, assets, shares, receiver, totalAssets)` (previously `(sender, shares, receiver, totalAssets)`).
  - `preWithdraw(sender, assets, shares, receiver, owner, totalAssets)` (previously `(sender, assets, receiver, owner, totalAssets)`).
  - `preRedeem(sender, assets, shares, receiver, owner, totalAssets)` (previously `(sender, shares, receiver, owner, totalAssets)`).
  - All existing periphery hooks updated to the new signatures.
- **Gas optimization refactor** (`ConcreteStandardVaultImpl`, PR #176): Per-config setters (`updateManagementFee`, `updatePerformanceFee`, `setHurdleRateOracle`, `setDepositLimits`, `setWithdrawLimits`) are now exposed through the single `configure` entry point to reduce bytecode size. The duplicate `notPaused` modifier was removed. PR #190 follows up with the test migration to the new entry point (`ead109e`).
- **Reentrancy guard** (`UpgradeableVault`): Switched from `ReentrancyGuardUpgradeable` (storage-based) to `ReentrancyGuardTransient` (EIP-1153 transient storage) for cheaper per-tx gas. `__ReentrancyGuard_init()` call removed from `_upgradeableVaultInit`.
- **`HookContainer`** (`src/periphery/hooks/HookContainer.sol`): All hook entry points are now gated with `onlyVault`. `setHook` now accepts `address(0)` to explicitly disable a hook slot.
- **`UserDepositCapHook`** (`src/periphery/hooks/UserDepositCapHook.sol`): Moved from global cap tracking to per-vault cap tracking; the hook now reads and writes cap usage against the calling `vault()`.
- **`WhitelistUserDepositHook`**: Rebased on top of the new hook signatures and per-vault context.

### Removed

- **`DepositLockHook.previewWithdraw`**: The deprecated preview helper was removed; callers should use the standard ERC-4626 preview path plus the hook's `getLockedAmount(user)` view.

### Fixed

#### Audit remediations (Halborn — Earn v1.4, May 2026)

- **HAL-10 — `ConcreteAsyncVaultImpl._upgrade`**: Added an override of `_upgrade` so that vaults upgraded from a non-async implementation through `ConcreteFactory.upgrade` correctly initialise the async-specific storage (`isQueueActive`, `latestEpochID`, `unwindCostCapBP`) and role admins (`WITHDRAWAL_MANAGER`, `PRIORITY_WITHDRAWAL_EXECUTOR`). All upgrade-time work (legacy role migration via `RoleMigrationLib` plus the idempotent async init gated on `latestEpochID == 0`) is consolidated in a new `StateInitLib.stateUpgradeAsyncVaultImpl()` library entry point invoked via DELEGATECALL, which keeps the implementation's runtime bytecode within the EIP-170 limit. Async → Async upgrades preserve in-flight epochs and operator-tuned config. `ConcreteBridgedAsyncVaultImpl` inherits the fix automatically. Two new tests under `test/unit-test/ConcreteAsyncVaultImpl/UpgradeToAsync.t.sol` cover both the Standard → Async init path and the Async → Async no-reinit invariant.
- **HAL-08 — `ConcreteStandardVaultImpl` ERC-4626 capacity views under pause**: `maxDeposit`, `maxMint`, `maxWithdraw`, and `maxRedeem` now return `0` when the vault is paused, complying with the EIP-4626 clause that requires capacity views to return `0` whenever the corresponding operation is disabled — even temporarily. The check is `paused()`-only and intentionally does not zero out `maxWithdraw` / `maxRedeem` in async queue mode, where the underlying `withdraw` / `redeem` are not disabled but rather enqueue requests for epoch settlement. `ConcreteAsyncVaultImpl` inherits the change automatically. Four targeted unit tests were added.
- **HAL-06 — `DepositLockWithFeeHook.setMinLockPeriod` / `setDepositLockDuration` re-enable ordering**: Documentation-only clarification. Added NatSpec on both setters describing the cross-parameter constraint: when `depositLockDuration == 0` (locking disabled) and `minLockPeriod > 0`, any subsequent `setDepositLockDuration(newDuration)` with `newDuration <= minLockPeriod` reverts with `MinLockPeriodExceedsDuration`. The recovery path is `setMinLockPeriod(0)` (or to a value strictly less than the intended new duration) first, then `setDepositLockDuration(newDuration)`, then optionally `setMinLockPeriod` again. No logic change.
- **HAL-03 — `DepositLockHook.setMaxLocksPerUser`**: The setter now enforces both a lower and an upper bound on the per-user lock cap. It reverts with the new `ZeroMaxLocks()` error when called with `0`, and with the new `MaxLocksPerUserAboveCeiling(requested, ceiling)` error when called with a value strictly above the new public constant `MAX_LOCKS_PER_USER_CEILING = 500`. The lower bound closes the configuration footgun where `maxLocksPerUser = 0` disabled the per-user cap; the upper bound caps the residual cross-user griefing surface (a third party filling a victim's lock slots via on-behalf-of deposits) by guaranteeing that even the worst-case O(N) per-user paths — `_cleanupExpired`, `_removePrefix`, sorted-insert in `_appendLock` — fit in a single transaction with a >30x margin against a 30M block gas limit (empirical worst-case sorted-insert at the ceiling is under 1M gas), so the victim can always exit post-expiry. The branch `if (maxLocks != 0 && pending >= maxLocks)` in `_appendLock` is simplified to `if (pending >= maxLocks)` because the cap is now guaranteed `> 0`. Spec and tests updated.

#### Other fixes

- **`OffchainHurdleRateOracle.setMaxStaleness`**: Reverts with `MaxStalenessTooHigh` when the new value exceeds `DEFAULT_MAX_STALENESS`, closing a configuration hole flagged in audit remediation.
- **`WithdrawLib` — ERC-4626 compliance fix**: `maxWithdraw` / `maxRedeem` now return `0` when available liquidity falls below `minTxWithdrawAmount`, preventing the preview functions from advertising amounts that `withdraw` / `redeem` would then reject. Continuation of the v1.2.0 remediation on minimum transaction amounts. (Commit `5dd048d`.)
- **Partial epoch processing**: Unified `epochID` validation between `processPartialEpochRequest` and `moveRequestToNextEpoch`, preventing off-by-one and wrong-epoch edge cases.
- **Deposit lock hooks — edge cases addressed during review**:
  - `duration == 0` now reverts with `InvalidDuration` at configuration time.
  - Sorted insertion invariant enforced on `_appendLock`; locks array stays ordered by `unlockTimestamp` even under interleaved deposits.
  - Early check of locked vs. requested amount on withdrawal paths (short-circuit before hook expansion).
  - Removed a brittle invariant requirement that no longer held under sorted insertion.
- **Test migration**: `ead109e` — tests that touched `setDepositLimits` / `setWithdrawLimits` directly were migrated to `configure(VaultManagerConfig.DepositLimits, abi.encode(...))` / `configure(VaultManagerConfig.WithdrawLimits, abi.encode(...))`.

### Security

- The full `main..dev/earn-1.4` diff is packaged for external audit under `audit/scope/` (`scope-src.patch`, `scope-full.patch`, `commits.txt`, `files-stat.txt`, plus `README.md` with per-topic breakdown).

## [1.3.0] - 2026-04-20

### Added

- **Position Management Helper (PMH)** — standalone, non-upgradeable operator contracts that manage a leveraged lend/borrow position on behalf of an external `positionOwner` account (e.g. a multisig). Each helper holds no tokens at rest (zero-balance invariant); tokens only transit during a transaction.
  - **`PositionHelperBase`** (`src/periphery/positionhelper/PositionHelperBase.sol`): Abstract base contract. Deployed as a [ClonesWithImmutableArgs](https://github.com/wighawag/clones-with-immutable-args) implementation; each position gets its own lightweight clone. The 62-byte immutable-arg payload encodes `positionOwner` (20 bytes), `collateralToken` (20 bytes), `borrowToken` (20 bytes), `collateralDecimals` (1 byte), and `borrowDecimals` (1 byte). Inherits `AccessControlEnumerableUpgradeable`, implements both `ILenderModule` and `IContractId`. Exposes two roles: `POSITION_ADMIN_ROLE` and `POSITION_OPERATOR_ROLE`.

  - **`PositionHelperAaveV3`** (`src/periphery/positionhelper/PositionHelperAaveV3.sol`): Concrete Aave V3 lender integration. Sets Aave infrastructure immutables (`POOL`, `DATA_PROVIDER`, `ADDRESSES_PROVIDER`, `PRICE_ORACLE`) at construction time, shared across all clones from this implementation. Variable-rate borrow mode (`INTEREST_RATE_MODE = 2`). Contract ID: **`400110100`** (type=4 / position-helper, flavour=1 / aave-v3, v1.1.1).

  - **Exposed operations** (accessible by `POSITION_OPERATOR_ROLE`):
    - Primitive lender ops: `supply`, `withdraw`, `borrow`, `repay`
    - Self-liquidation: `selfLiquidate(debtAmount, maxSlippageInWad)` and `selfLiquidateToLtv(targetLtvInWad, maxSlippageInWad)` — flash-loan-assisted partial or full position unwinds
    - Target vault ops: `depositOnTarget`, `requestRedemptionFromTarget`, `updateRedemptionRequestFromTarget`, `cancelRedemptionRequestFromTarget`, `claimRedemptionFromTarget`
    - Async queue priority management: `requestPriorityRedemptionFromTarget`, `revokePriorityRedemptionFromTarget`
    - High-level flows: `deploy(collateralAmount, targetLtvInWad)` — supply → borrow → deposit in one call; `retract(repayAmount, withdrawalAmount, maxPermissibleLtv)` — repay → withdraw in one call
    - Compound flows: `claimAndRetract` (claim fulfilled redemptions then retract), `redeemAndRetract` (sync redeem then retract)
    - Admin: `rescueFunds(token, amount)` for emergency ERC-20 recovery
  - **View helpers**: `checkApprovals()` returns a `PositionApprovals` struct with the status of every required approval and role in a single call; `calculateTargetRepayAmount(requiredPrincipalAmount, targetLtvInWad)` computes the borrow-token repay amount needed to reach a target LTV after a given withdrawal.
  - **Shared types** (`IPositionHelperBase`): `PositionApprovals`, `SelfLiqState`, `TargetOwnerAmount`.
  - Each clone is granted co-ownership of the position: pre-approved allowances for `collateralToken → pool`, `collateralToken → swapModule`, `borrowToken → pool`, `borrowToken → yieldVault`, `borrowToken → flashModule`, and `yieldVault shares → yieldVault` are set once at `initialize()`.

- **`PositionManagementHelperLib`** (`src/periphery/lib/PositionManagementHelperLib.sol`): Pure math library for LTV-based position sizing. All LTVs in WAD (1e18 = 100%), prices in RAY (1e27). Functions: `withdrawable`, `borrowAmountForTargetLtv`, `redepositAmount`, `minLtv`.

- **`PositionManagementHelperStorageLib`** (`src/periphery/lib/PositionManagementHelperStorageLib.sol`): EIP-7201 namespaced storage struct for PMH clones (`PMHStorage`). Fields: `target`, `flashModule`, `swapModule`, `selfLiqThrBufferInWad`, `healthyLtvInWad`, `healthyLtvDeviationInWad`, `withdrawalRequestEpoch`.

- **`PeripheryFactory`** (`src/periphery/factory/PeripheryFactory.sol`): UUPS upgradeable, owner-controlled factory that deploys and manages both strategy proxies and PMH clones under a single registry.
  - **Strategy side**: `approveStrategyImpl`, `blockStrategyImpl`, `setStrategyMigratable`, `deployStrategy(implId, initData)`, `upgradeStrategy(proxy, newImplId, data)`, `batchUpgradeStrategies`. Strategy proxies are ERC-1967 UUPS proxies; the factory holds `STRATEGY_UPGRADER` on each deployed strategy. Caller of `upgradeStrategy` must hold `ROLE_ADMIN` on the target strategy.
  - **PMH clone side**: `approvePMHImpl`, `blockPMHImpl`, `clonePMH(implId, positionOwner, collateralToken, borrowToken, initData)`. Clone deployment reads token decimals on-chain and encodes the full 62-byte immutable-arg payload automatically.
  - Both sides are keyed by `IContractId.ID()`.

- **`PeripheryFactoryStorageLib`** (`src/periphery/lib/PeripheryFactoryStorageLib.sol`): EIP-7201 namespaced storage for `PeripheryFactory`.

- **`clones-with-immutable-args`** library added as a git submodule (`lib/clones-with-immutable-args`).

- **Documentation**:
  - `doc/spec/ThePierreLtvAssistent.md`: full position-model spec (7-tuple `(a, b, c, d, s, q, r)`, flows, math).
  - `doc/the-pierre-backend-integration.md`: backend integration guide.
  - `doc/position-helper-architecture.html`, `doc/architecture-diagram.svg`, `doc/state-machine-diagram.svg`: architecture and state-machine visuals.

- **Tests**:
  - `test/periphery/unit-test/PositionHelperAaveV3Test.t.sol`: unit tests for `PositionHelperAaveV3` (deploy, retract, self-liquidation, approvals, view helpers).
  - `test/periphery/unit-test/PositionManagementHelperLibTest.t.sol`: unit tests for all pure math functions in `PositionManagementHelperLib`.
  - `test/periphery/unit-test/PeripheryFactoryUnitTest.t.sol`: unit tests for `PeripheryFactory` (strategy and PMH registration, deployment, upgrade, block, batch-upgrade, all error paths).
  - `test/periphery/E2E/PositionHelperAaveV3E2ETest.t.sol`: fork-based end-to-end tests against live Aave V3 markets.
  - `test/periphery/E2E/PositionHelperLiquidationE2ETest.t.sol`: fork-based self-liquidation scenario tests.

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

## [1.1.0] - 2026-02-14

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

## [1.0.6] - 2026-02-06

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

[1.7.1]: https://www.npmjs.com/package/@concrete-xyz/earn-v2-core/v/1.7.1
[1.7.0]: https://www.npmjs.com/package/@concrete-xyz/earn-v2-core/v/1.7.0
[1.6.0]: https://www.npmjs.com/package/@concrete-xyz/earn-v2-core/v/1.6.0
[1.5.1-Beta]: https://www.npmjs.com/package/@concrete-xyz/earn-v2-core/v/1.5.1-beta
[1.5.0]: https://www.npmjs.com/package/@concrete-xyz/earn-v2-core/v/1.5.0
[1.4.1]: https://www.npmjs.com/package/@concrete-xyz/earn-v2-core/v/1.4.1
[1.4.0]: https://www.npmjs.com/package/@concrete-xyz/earn-v2-core/v/1.4.0
[1.3.0]: https://www.npmjs.com/package/@concrete-xyz/earn-v2-core/v/1.3.0
[1.2.0]: https://www.npmjs.com/package/@concrete-xyz/earn-v2-core/v/1.2.0
[1.1.0]: https://www.npmjs.com/package/@concrete-xyz/earn-v2-core/v/1.1.0
[1.0.6]: https://www.npmjs.com/package/@concrete-xyz/earn-v2-core/v/1.0.6
[1.0.2]: https://www.npmjs.com/package/@blueprint-finance/earn-v2-core/v/1.0.2
[1.0.1]: https://www.npmjs.com/package/@blueprint-finance/earn-v2-core/v/1.0.1
[1.0.0]: https://www.npmjs.com/package/@blueprint-finance/earn-v2-core/v/1.0.0
