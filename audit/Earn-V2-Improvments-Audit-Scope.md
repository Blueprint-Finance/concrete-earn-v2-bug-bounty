# Audit Scope — v1.1.0

> Full prose motivation and design rationale is in `RELEASE_NOTES.md`. Concise bullet-point summaries are in `CHANGELOG.md`. 

---

## 1. Contract ID System

**Status: New**

Each contract implementation now carries a hardcoded pure `ID() returns (uint64)` that encodes its type, flavour, and semantic version using a packed decimal scheme.

- `src/lib/ContractIdEncoding.sol`: **New** — encoding/decoding library
- `src/interface/IContractId.sol`: **New** — `ID()` interface
- `src/common/UpgradeableVault.sol`: Modified — `ID()` declared as pure virtual
- `src/strategy/BaseStrategy.sol`: Modified — `ID()` declared as pure virtual
- All concrete vault/strategy implementations: Modified — `ID()` overridden with hardcoded value

---

## 2. Role System Simplification

**Status: Changed (breaking for governance tooling, not for users)**

All per-role admin roles replaced by a single `ROLE_ADMIN`. Two new base contracts resolve a diamond-inheritance conflict in OZ's access control hierarchy.

- `src/lib/Roles.sol`: Modified — `ROLE_ADMIN`, `PAUSER`, `PRIORITY_WITHDRAWAL_EXECUTOR` added; legacy admin roles removed from active use
- `src/lib/LegacyAdminRolesLib.sol`: **New** — enumerates deprecated admin role constants for migration
- `src/lib/RoleMigrationLib.sol`: **New** — upgrade-time migration: promotes first `VAULT_MANAGER_ADMIN` holder to `ROLE_ADMIN`, revokes all legacy admin roles
- `src/lib/AccessControlLib.sol`: Modified — `_getRoleMemberCount`, `_getRoleMember`, `_revokeRole` helpers added
- `src/periphery/lib/PeripheryRolesLib.sol`: Modified — `OPERATOR_ADMIN`, `STRATEGY_ADMIN_ADMIN` removed; `PAUSER`, `HOOK_MANAGER_ROLE`, `ROLE_ADMIN` added
- `src/common/AccessControlDefaultAdminRulesEnumerable.sol`: **New** — non-upgradeable base combining `AccessControlDefaultAdminRules` + `AccessControlEnumerable`
- `src/common/AccessControlDefaultAdminRulesEnumerableUpgradeable.sol`: **New** — upgradeable counterpart
- `src/strategy/BaseStrategy.sol`: Modified — base changed from `AccessControlUpgradeable` to `AccessControlEnumerableUpgradeable`

**Key questions for auditors:**
- `RoleMigrationLib` is called inside `_initialize` on upgrade — verify it cannot be triggered more than once and that the promoted address is the correct one.

---

## 3. Pause System

**Status: New (pause capability) / Changed (access control on existing pause)**

A dedicated `PAUSER` role now controls `pause()`/`unpause()` at both vault and strategy level. `whenNotPaused` has been applied broadly.

- `src/implementation/ConcreteStandardVaultImpl.sol`: Modified — `whenNotPaused` on `allocate`, `accrueYield`, `setHooks`, strategy management, deposit/withdraw limit setters
- `src/implementation/ConcreteAsyncVaultImpl.sol`: Modified — `whenNotPaused` on all epoch lifecycle functions in addition to the above
- `src/strategy/BaseStrategy.sol`: Modified — `PAUSER` role for `pause`/`unpause`; `whenNotPaused` on `setMaxWithdraw`, `rescueToken`
- `src/periphery/strategies/BaseLoopingStrategy.sol`: Modified — `onlyAdminOrOperatorWhenNotPaused` modifier; `whenNotPaused` on permissionless `adjustLeverage`

**Key questions for auditors:**
- Are all critical state-changing paths covered by `whenNotPaused`? Check for any paths that bypass the guard.

---

## 4. Factory — ID-Based Implementation Registry

**Status: Changed**

Implementations registered by their self-declared `IContractId.ID()` instead of a sequential index. Legacy fallback retained.

- `src/factory/ConcreteFactory.sol`: Modified — `approveImplementation`, `_isValidVaultImpl`, `blockImplementationByAddress`, `setMigratableByAddress` updated
- `src/lib/storage/ConcreteFactoryBaseStorageLib.sol`: Modified — `vaultImplToImplementation: mapping(uint64 => address)` added; `implementations` set renamed to `legacyImplementationSet`
- `src/lib/storage/DefaultEnforcedVaultConfigStorageLib.sol`: **New** — EIP-7201 storage for default fee recipients
- `src/interface/IDefaultEnforcedVaultConfiguration.sol`: **New** — struct + interface for default fee config

**Key questions for auditors:**
- Can `_isValidVaultImpl` fallback to the legacy set be exploited to approve an un-audited implementation?

---

## 5. Priority Withdrawal Queue

**Status: New**

Immediate (out-of-epoch) fulfilment of queued async withdrawal requests.

- `src/implementation/ConcreteAsyncVaultImpl.sol`: Modified — `claimPriorityWithdrawal`, `setUnwindCostCap`, `getUnwindCostCap` added
- `src/lib/AsyncVaultHelperLib.sol`: Modified — `claimPriorityWithdrawal` core logic extracted here
- `src/interface/IAsyncAccounting.sol`: **New** — `adjustTotalAssets(int256)` interface
- `src/periphery/strategies/MultisigStrategy.sol`: Modified — implements `IAsyncAccounting`; vault-only caller path bypasses nonce/threshold/cooldown

**Key questions for auditors:**
- Can the same epoch withdrawal request be claimed twice (once via priority, once via normal epoch processing)?

---

## 6. Deposit / Withdraw Limit Rename

**Status: Changed (semantics change for `maxGlobalDepositAmount`)**

`maxDepositAmount` → `maxGlobalDepositAmount`: semantics changed from per-transaction cap to total vault assets cap. All other renames are cosmetic only.

- `src/lib/StateInitLib.sol`: Modified — field renames
- `src/lib/StateSetterLib.sol`: Modified — field renames
- `src/lib/storage/ConcreteStandardVaultImplStorageLib.sol`: Modified — storage field renames

**Key question for auditors:** Verify that `maxDeposit` / `maxMint` correctly account for the new global semantics after `_previewAccrueYieldAndFees` is applied.

---

## 7. HookContainer

**Status: New**

Composable hook dispatcher: implements `IHook`, dispatches to up to 6 sub-hooks.

- `src/periphery/hooks/HookContainer.sol`: **New** — main contract
- `src/periphery/lib/HookContainerStorageLib.sol`: **New** — EIP-7201 namespaced storage
- `src/lib/Hooks.sol`: Modified — `HooksLibV1.setFlag(h, flagIndex)` helper added

---

## 8. Standard Vault — External Library Extraction

**Status: Changed (refactor for bytecode size; behaviour unchanged)**

Yield accrual, withdrawal execution, and deposit/withdraw limit calculations extracted from `ConcreteStandardVaultImpl` into three separately-deployed libraries, called via DELEGATECALL. Same pattern as §9 (Looping Strategy).

- `src/lib/YieldAccrualLib.sol`: **New** — `accrueYield`, `accrueManagementFee`, `accruePerformanceFee`, and associated preview helpers (all `public`, deployed as a separate contract)
- `src/lib/WithdrawLib.sol`: **New** — `executeWithdrawFromStrategies` (`public`, deployed as a separate contract)
- `src/lib/StandardVaultHelperLib.sol`: **New** — `calcMaxDeposit`, `calcMaxMint`, `calcMaxWithdraw`, `calcMaxRedeem` (`internal pure`, inlined at call site); `calcTotalAllocated` (`public view`)
- `src/implementation/ConcreteStandardVaultImpl.sol`: Modified — imports the three new libraries; `_maxDeposit`, `_maxMint`, `_maxWithdraw`, `_maxRedeem` private helpers added that delegate to `StandardVaultHelperLib`; yield and withdrawal paths delegate to `YieldAccrualLib` / `WithdrawLib` via DELEGATECALL
- `src/lib/ERC20Lib.sol`: Modified — `totalSupply()` public view function added (required by `YieldAccrualLib`)

**Key questions for auditors:**
- All three libraries operate on vault storage via DELEGATECALL. Verify every EIP-7201 storage slot access uses the same keys as the vault's own storage libs (`ConcreteStandardVaultImplStorageLib`, `ConcreteCachedVaultStateStorageLib`).
- `YieldAccrualLib.accrueYield` mints fee shares and updates cached state. Confirm it cannot be called reentrantly or in a way that double-mints fees.
- `WithdrawLib.executeWithdrawFromStrategies` iterates the deallocation order array from storage. Verify the loop cannot be griefed by a paused or malicious strategy that reverts.

---

## 9. Looping Strategy — External Library Extraction

**Status: Changed (refactor for bytecode size; behaviour unchanged)**

Heavy preview and lender-setter logic extracted from `BaseLoopingStrategy` into an external `BaseLoopingHelperLib` deployed as a separate contract, called via DELEGATECALL.

- `src/periphery/lib/Looping/BaseLoopingHelperLib.sol`: **New** — `previewOperationNonLooping`, `previewOperationLooping`, `setLenderModule`, internal helpers
- `src/periphery/strategies/BaseLoopingStrategy.sol`: Modified — `_previewOperation` delegates to library; `_setLenderModule` is a one-liner; `_lenderModuleState`, `_removeApprovalFromUnfundedLenderModule` removed; `_lenderModule()` helper added; `_checkAndStage` signature simplified; `virtual` removed from lender wrappers

---

## 10. Initializer Pattern

**Status: Changed (naming convention only)**

No logic changes. Strategy initialisers renamed to `__<ContractName>_init(...)`. `__BaseStrategy_init` marked `onlyInitializing`. Vault `_initialize` uses `msg.sender` instead of `_msgSender()`.

- `src/strategy/BaseStrategy.sol`: Modified
- All concrete strategy implementations: Modified

---

## 11. Interface Reorganisation

**Status: Changed**

- `src/interface/IUpgradeableVault.sol`: Modified — `IUpgradeableVaultBase` removed; `IUpgradeableVault` is now self-contained; `IUpgradeableVaultLegacy` is a new standalone interface for legacy single-argument `upgrade` callers
- `src/common/UpgradeableVault.sol`: Modified — import and `@inheritdoc` annotations updated; `version()` changed to `public`
- `src/factory/ConcreteFactory.sol`: Modified — `abi.encodeCall` updated to reference `IUpgradeableVault.initialize` directly

---

## Removed / Deprecated

- `VAULT_MANAGER_ADMIN`, `HOOK_MANAGER_ADMIN`, `STRATEGY_MANAGER_ADMIN`, `ALLOCATOR_ADMIN`, `WITHDRAWAL_MANAGER_ADMIN`: Vault-level per-role admin roles removed from active use; constants retained in `LegacyAdminRolesLib` for migration only
- `OPERATOR_ADMIN`, `STRATEGY_ADMIN_ADMIN`: Strategy-level per-role admin roles removed
- `IUpgradeableVaultBase`: Interface removed; contents folded into `IUpgradeableVault`
- `_lenderModuleState`, `_removeApprovalFromUnfundedLenderModule` on `BaseLoopingStrategy`: Moved to `BaseLoopingHelperLib`
- `getImplementationByVersion(uint64)`: Deprecated (still functional); superseded by `getImplementationByVaultImpl(uint64)`

---

## Files Not in Scope

The following areas are **unchanged** from the previously audited baseline and are not in scope for this audit cycle:

- Core ERC-4626 share conversion math (`Conversion.sol`) — comment move only, no logic change
- `LoopingPrimitive`, `LoopingPrimitiveLib`, `LoopModalityLib` (unchanged)
- `AaveV3LenderAdapter`, `LenderModuleAaveV3`, `FlashModuleAaveV3` (unchanged)
- `UniV3Swapper` (unchanged)
- `TwoWayFeeSplitter` (unchanged)
- Bridged vault implementations (`ConcreteBridgedStandardVaultImpl`, `ConcreteBridgedAsyncVaultImpl`) — `ID()` override added only (trivial, covered by §1)
- `UserDepositCapHook` — NatSpec comment fix only ("vault address" → "sender address")
- All other existing hook implementations (unchanged)
- Test suite

---

## Reference Documents

- `RELEASE_NOTES.md`: Verbose design rationale for each change area
- `CHANGELOG.md`: Bullet-point summary for the `[1.1.0]` release
