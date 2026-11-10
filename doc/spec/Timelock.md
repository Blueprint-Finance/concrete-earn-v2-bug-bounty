# Timelock — Implementation Spec

---

## 1. Overview

`Timelock` is a single, upgradeable, external contract that gates privileged calls on every protected contract (vault, factory, strategy, AssetCX, merchant, etc.). It is deployed once per environment and shared across all targets — schedule state, tier configuration, and the artifact registry live in the timelock, not the targets.

Each protected contract holds only two things:

1. The timelock address.
2. An `afterDelay` modifier that delegates a `checkDelayExpired(msg.sig, msg.data[4:])` call to the timelock.

Original `onlyRole` / `onlyOwner` checks on protected contracts are untouched. The delay is layered on top of the existing authorization surface, not in place of it.

---

## 2. Architecture

```
                       ┌──────────────────────────────────────┐
                       │              Timelock                │
   propose ───────────▶│  schedules[actionId] = readyAt       │
                       │  artifactDelayTier[type][artifact]   │
                       │  contractTypeOf[target]              │
   checkDelayExpired ──│  (UUPS, AccessControlEnumerable)     │
                       └──────────────────────────────────────┘
                                        ▲
                                        │ ITimelock.checkDelayExpired
                                        │
        ┌───────────────────────────────┼───────────────────────────┐
        │                               │                           │
┌──────────────┐               ┌──────────────────┐         ┌─────────────────┐
│ Vault        │               │ Factory          │         │ Strategy / ...  │
│ setTimelock  │               │ setTimelock      │         │ setTimelock     │
│ afterDelay   │               │ afterDelay       │         │ afterDelay      │
└──────────────┘               └──────────────────┘         └─────────────────┘
                       (each uses `TimelockIntegrationLib`)
```

- **`Timelock`** (`src/periphery/timelock/Timelock.sol`): UUPS upgradeable, `AccessControlEnumerableUpgradeable`, EIP-7201 storage (`TimelockStorageLib`).
- **`ITimelock`** (`src/periphery/interface/ITimelock.sol`): canonical external surface.
- **`ITimelockProtected`** (`src/interface/ITimelockProtected.sol`): shared `setTimelock` / `activateTimelock` / `getTimelock` surface implemented by every protected contract.
- **`TimelockIntegrationLib`** (`src/lib/TimelockIntegrationLib.sol`): inlined into protected contracts; owns its own EIP-7201 slot (`concrete.storage.TimelockIntegration`) for `(timelock, active)` and exposes `enforceDelay` / `setTimelock` / `activateTimelock` / `state`.

---

## 3. Lifecycle

```
  ┌──────────┐  propose   ┌──────────────┐   wait (tier delay)   ┌─────────┐
  │ PROPOSER ├───────────▶│ scheduled    ├───────── … ──────────▶│ matured │
  └──────────┘            │ readyAt = ts │                       └────┬────┘
                          └──┬───────────┘                            │
                cancel       │           ┌──────────────────────────  │
              (GUARDIAN) ◀───┤           │ STALENESS_WINDOW (2 weeks) │
                             │           ▼                            │
                             │     ┌──────────┐  pruneStale           │
                             │     │  stale   ├───────────────▶ ∅     │
                             │     └──────────┘ (JANITOR)             │
                             │                                        ▼
                             │                              ┌──────────────────┐
                             │                  execute ───▶│ checkDelayExpired│──▶ ∅
                             │  overrideTimelock            │  (target side)   │
                             └────── (OVERRIDE) ────────────▶ readyAt := now   │
                                                            └──────────────────┘
```

**One pass through the system:**

1. `PROPOSER_ROLE` → `propose(target, selector, args)` on the timelock.
   - Resolves `contractType = contractTypeOf[target]`.
   - Resolves `artifact` = role identifier (for `grantRole`) or `bytes32(selector)`.
   - Resolves `tier = artifactDelayTier[contractType][artifact]`.
   - Writes `schedules[actionId] = now + tierDelay[tier]` where `actionId = keccak256(abi.encode(target, selector, args))`.
   - Reverts `DuplicateAction` if an entry already exists.
2. Wait until `readyAt`.
3. Anyone authorized by the protected contract's original `onlyRole` calls the setter directly. Its `afterDelay` modifier invokes `checkDelayExpired(msg.sig, msg.data[4:])`. Inside the timelock:
   - `msg.sender` = the protected contract = the `target` from step 1.
   - Recomputes the same `actionId`, validates `readyAt ≤ now ≤ readyAt + STALENESS_WINDOW`, deletes the entry, emits `Consumed`.
4. Side branches:
   - `GUARDIAN_ROLE` → `cancel(actionId)` deletes any queued entry.
   - `OVERRIDE_ROLE` → `overrideTimelock(actionId)` re-stamps `readyAt = block.timestamp` (compresses the remaining delay to zero). The action still needs to be executed by the original `onlyRole` holder and is still cancellable.
   - `JANITOR_ROLE` → `pruneStale(actionId)` reaps entries past `readyAt + STALENESS_WINDOW`.

`activateTimelock()` is a one-way switch that flips `active = true`. Until then, `checkDelayExpired` returns immediately — useful for bootstrap configuration without delays.

---

## 4. Tier model

Three tiers, ordered by risk (highest → lowest):

| Tier   | Code         | Default delay | Bound       | Notes                          |
| ------ | ------------ | ------------- | ----------- | ------------------------------ |
| TIER_1 | `0x00000001` | **48 h**      | highest     | upgrades, ownership transfer   |
| TIER_2 | `0x00000002` | **24 h**      | medium      | most operational mutators      |
| TIER_3 | `0x00000003` | **12 h**      | lowest      | low-blast operational grants   |

Invariant — `TIER_1 ≥ TIER_2 ≥ TIER_3 ≥ MIN_DELAY` — is enforced by `updateTierDelay` (`TierOrderViolation`). Each delay is also bounded by `MIN_DELAY = 6 h` and `MAX_DELAY = 30 days`. `bytes4(0)` is the sentinel for "unregistered" in the artifact registry and is not a valid tier.

Defaults and per-target seedings live in `TimelockConfigurationLib` and are written in `initialize` (`seedTierDelayDefaults` + the per-target `seedXArtifacts` helpers).

---

## 5. Artifact registry

State (see `TimelockStorageLib`):

```solidity
mapping(bytes4 tier => uint256 delay)                                    tierDelay;
mapping(bytes4 contractType => mapping(bytes32 artifact => bytes4 tier)) artifactDelayTier;
mapping(bytes32 actionId => uint256 readyAt)                             schedules;
mapping(address protectedContract => bytes4 contractType)                contractTypeOf;
bool                                                                     active;
```

**Artifact encoding.** A single `bytes32` key carries two kinds of entries — collision risk ≈ 2⁻²²⁴:

- **Function selectors**: `artifact = bytes32(bytes4(selector))` (4 bytes left-aligned, 28 trailing zero bytes).
- **Role identifiers** (only for `grantRole(role, account)` proposals): `artifact = role` (full `keccak256` hash).

`Timelock._artifactFor(selector, args)` makes this decision: it special-cases `IAccessControl.grantRole.selector` and ABI-decodes the role from `args`; everything else falls through to the selector form.

**Contract types** (`TimelockContractTypesLib`): `CT_TIMELOCK`, `CT_VAULT`, `CT_FACTORY`, `CT_STRATEGY`, `CT_PERIPHERY_FACTORY`, `CT_HOOK_CONTAINER`, `CT_ORACLE_MODULE`, `CT_ASSETCX`, `CT_ASSETCX_LIQUIDATION_MODULE`, `CT_MERCHANT`, `CT_REDEMPTION_CLAIM_TOKEN`. Each is `bytes4(keccak256("<NAME>"))`.

When a release adds artifacts (as 1.7 did with `CT_ORACLE_MODULE`), already-deployed timelocks pick them up via `reinitializeV3()` (`UPGRADER_ROLE`, called through `upgradeToAndCall`). It re-seeds all artifact registries (and the timelock's own binding) without touching tier delays, schedules, contract bindings, role membership or the `active` flag.

**Mutation paths**:

- `addArtifact(contractType, artifact, tier)` — register-only; reverts `ArtifactAlreadyRegistered` if the pair is already present. **Not self-timelocked** (low blast: only enables new gating, cannot weaken existing).
- `changeTier(contractType, artifact, newTier)` — re-tiers an existing pair. **Self-timelocked at TIER_1** (changes effective delays for every future proposal).
- `bindContract(target, contractType)` — binds a target. **Not self-timelocked** (binding only enables gating; rebinding requires `unbindContract` first).
- `unbindContract(target)` — removes a binding. **Self-timelocked at TIER_2**. *Does not* cancel queued actions targeting the address — `checkDelayExpired` doesn't consult `contractTypeOf`, only `schedules`.

---

## 6. Roles

All authorization for timelock operations lives on the timelock contract (`TimelockRolesLib`):

| Role            | Constant                 | What it does                                            | Bypassed by override? |
| --------------- | ------------------------ | ------------------------------------------------------- | --------------------- |
| `PROPOSER_ROLE` | `TIMELOCK_PROPOSER_ROLE` | `propose` (queues actions)                              | n/a                   |
| `GUARDIAN_ROLE` | `TIMELOCK_GUARDIAN_ROLE` | `cancel` (deletes queued)                               | n/a                   |
| `CONFIG_ROLE`   | `TIMELOCK_CONFIG_ROLE`   | `addArtifact`, `changeTier`, `bindContract`, `unbindContract`, `updateTierDelay` | most operations are self-timelocked |
| `OVERRIDE_ROLE` | `TIMELOCK_OVERRIDE_ROLE` | `overrideTimelock` (compresses `readyAt` to now)        | itself, by design     |
| `UPGRADER_ROLE` | `TIMELOCK_UPGRADER_ROLE` | UUPS `upgradeToAndCall` (self-timelocked at TIER_1)     | n/a                   |
| `JANITOR_ROLE`  | `TIMELOCK_JANITOR_ROLE`  | `pruneStale` (reaps stale entries)                      | n/a                   |
| `DEFAULT_ADMIN_ROLE` | OZ default          | `activateTimelock` (one-shot), role admin               | n/a                   |

**`grantRole` overrides** (`Timelock.grantRole`): granting `CONFIG_ROLE`, `OVERRIDE_ROLE`, or `UPGRADER_ROLE` self-triggers the timelock (TIER_2 / TIER_1 / TIER_1 respectively). Granting `PROPOSER_ROLE`, `GUARDIAN_ROLE`, or `JANITOR_ROLE` is immediate.

**Self-timelocked admin surface** (registered under `CT_TIMELOCK`):

| Selector                  | Tier   |
| ------------------------- | ------ |
| `upgradeToAndCall`        | TIER_1 |
| `updateTierDelay`         | TIER_1 |
| `changeTier`              | TIER_1 |
| `unbindContract`          | TIER_2 |
| `_authorizeUpgrade` hook  | (gated by `afterDelay` on the inherited UUPS path) |

**Separation requirements** (operational, not enforced on-chain): `GUARDIAN ↔ everything`, `CONFIG ↔ OVERRIDE`, `OVERRIDE ↔ PROPOSER / admin`. Initial deployments grant all six roles to the bootstrap admin; reassign to dedicated multisigs before `activateTimelock`.

---

## 7. Integration on a protected contract

Every protected contract uses `TimelockIntegrationLib` and implements `ITimelockProtected`. Concrete pattern (already in `BaseStrategy`, `ConcreteFactory`, etc.):

```solidity
import {TimelockIntegrationLib} from "src/lib/TimelockIntegrationLib.sol";
import {ITimelockProtected}     from "src/interface/ITimelockProtected.sol";

modifier afterDelay() {
    TimelockIntegrationLib.enforceDelay(msg.sig, msg.data[4:]);
    _;
}

function setTimelock(address t) external onlyRole(ADMIN) {
    TimelockIntegrationLib.setTimelock(t);
    emit TimelockSet(t);
}

function activateTimelock() external onlyRole(ADMIN) {
    address t = TimelockIntegrationLib.activateTimelock();
    emit TimelockActivated(t);
}

function someProtectedSetter(uint256 v) external onlyRole(MANAGER) afterDelay {
    _value = v;
}
```

**Why a library, not a base contract:**

- All functions are `internal` → inlined, zero DELEGATECALL overhead.
- Owns its own EIP-7201 storage slot (`concrete.storage.TimelockIntegration` → `0x7d38a0bb…`), independent of the contract's main storage struct, so storage layout is stable across upgrades.
- Events (`TimelockSet`, `TimelockActivated`) belong on the calling contract's ABI and are emitted in the wrappers above.

**Activation gate.** `enforceDelay` no-ops while `active == false`, so the bootstrap operator can wire roles, bind contracts, and seed configuration before flipping the switch. `activateTimelock` reverts `TimelockAlreadyActive` if called twice or `TimelockNotSet` if no address is configured.

---

## 8. Edge cases

- **Staleness window.** `STALENESS_WINDOW = 2 weeks`. A matured entry not consumed within that window becomes `ActionStale`. Resolutions: `cancel` (Guardian) or `overrideTimelock` (re-stamps `readyAt = now`, revives the entry). `pruneStale` (Janitor) deletes the entry.
- **Duplicate proposals.** `propose` reverts `DuplicateAction` if `schedules[actionId] != 0`. Re-proposing the same `(target, selector, args)` requires consumption, cancellation, or pruning first.
- **Unbinding with queued entries.** `unbindContract` does not iterate `schedules`. Already-queued actions remain consumable. To fully retire a target, Guardian should `cancel` each pending entry first.
- **`changeTier` does not retro-apply.** Already-queued entries keep the `readyAt` computed at `propose` time. Only proposals made after the change pick up `newTier`.
- **Self-upgrade.** `Timelock._authorizeUpgrade` carries `onlyRole(UPGRADER_ROLE) afterDelay`. Upgrading the timelock therefore requires the standard `propose → wait → upgrade` flow, with the same `cancel` / `override` levers available as for any other protected function. No privileged escape hatch.
- **`bindContract` is intentionally not self-timelocked**, while `unbindContract` is — binding only enables new gating; unbinding removes it, which is the higher-impact direction.

---

## 9. Restrictive vs. additive delay asymmetry

The delay is deliberately **one-directional**: functions that *widen* a privileged
surface (`addHook`, `replaceHook`, `addToWhitelist`, `grantRole`) are gated by
`afterDelay` / `_enforceDelay()` and only take effect once a proposal has matured.
Functions that *narrow* that surface are, with one exception (see below),
intentionally instant:

- `RedemptionClaimToken.removeFromWhitelist()`
- `revokeRole()` / `renounceRole()` on `HookContainer`, `AssetCX`, `ConcreteMerchant`,
  `RedemptionClaimToken`, and `DolomiteLiquidationModule`

This is an **intentional emergency kill switch**: a trusted role holder must be able
to shut off a compromised or misbehaving component (a bad whitelist
entry, a bad operational role) in a single transaction, without waiting out a tier
delay while the system remains exposed. No state is permanently bricked by an
instant reduction — every reduction has an additive inverse (`addToWhitelist`, `grantRole`)
that the same trusted role can re-invoke, gated only by the standard delay, 
and the existing last-admin guard (see `_revokeRole` overrides on
`HookContainer` and `Timelock` itself) prevents an admin from locking out all
administrators. Any future advance-notice mechanism added to the protocol should
preserve this asymmetry: gate additive grants, keep restrictive corrections instant.

**Exception — `HookContainer.removeHook()`.** Although shaped like a restrictive
correction, removing a hook does not reduce the *caller's own* privilege — it lifts
whatever enforcement the hook was providing on other accounts (e.g. a
`DepositLockHook` / `DepositLockRegSHook`'s `preTransfer` / `preWithdraw` / `preRedeem`
restrictions). From the perspective of the accounts subject to that hook, removing it
is functionally an additive change, not a defensive one. `removeHook` is therefore
gated by `afterDelay` at `TIER_2` (`TimelockConfigurationLib.seedHookContainerArtifacts`),
the same tier as `addHook` / `replaceHook`, giving affected participants the same
advance notice before an enforcement hook is lifted as they get before one is added.
`replaceHook` remains the recommended path for swapping a hook atomically (no
intermediate block in which enforcement is absent); use `removeHook` only when no
replacement is being installed in the same window.

---

## 10. Quick reference

**Errors** (`ITimelock`): `UnknownAction`, `DuplicateAction`, `ActionNotReady`, `ActionStale`, `ActionNotYetStale`, `ArtifactNotRegistered`, `ArtifactAlreadyRegistered`, `UnknownTier`, `DelayOutOfBounds`, `TierOrderViolation`, `TargetNotBound`, `TargetAlreadyBound`, `AlreadyActive`, `ZeroAddress`.
Plus `Timelock.ZeroAdmin`. Integration lib emits `TimelockAlreadyActive`, `TimelockNotSet`, `ZeroAddress`.

**Events** (`ITimelock`): `Proposed`, `Consumed`, `Canceled`, `Overridden`, `TierDelayUpdated`, `ArtifactRegistered`, `ArtifactTierChanged`, `ContractBound`, `ContractUnbound`, `TimelockActivated`, `Pruned`. Plus `ITimelockProtected.TimelockSet` / `TimelockActivated` on each protected contract.

**Mutating selectors** (`Timelock`): `propose`, `cancel`, `pruneStale`, `overrideTimelock`, `updateTierDelay`, `addArtifact`, `changeTier`, `bindContract`, `unbindContract`, `activateTimelock`, `grantRole` (overridden), `upgradeToAndCall` (inherited, self-timelocked).

**Views** (`Timelock`): `tierDelay`, `artifactDelayTier`, `readyAt`, `contractTypeOf`, `isActive`, `computeActionId`, `MIN_DELAY`, `MAX_DELAY`, `STALENESS_WINDOW`.

**Constants**: `MIN_DELAY = 6h`, `MAX_DELAY = 30 days`, `STALENESS_WINDOW = 2 weeks`. Defaults: TIER_1 = 48h, TIER_2 = 24h, TIER_3 = 12h.

**Storage slots**: `Timelock` → `concrete.storage.Timelock` (`0xcfca85a4…`); integration lib → `concrete.storage.TimelockIntegration` (`0x7d38a0bb…`).
