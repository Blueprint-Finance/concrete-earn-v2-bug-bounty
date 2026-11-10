# PeripheryFactory — Specification

**Title:** PeripheryFactory — Unified periphery contract registry and deployment factory
**Authors:** Blueprint Finance
**Status:** Final
**Last updated:** 2026-11-04
**Package:** `@concrete-xyz/earn-v2-core@1.7.0`
**Source:** `src/periphery/factory/PeripheryFactory.sol`

**Related docs:**
- `doc/spec/PositionManagementHelper.md` — PMH spec
- `CHANGELOG.md` — release notes

---

## Overview

`PeripheryFactory` is a UUPS-upgradeable registry and deployment factory for three classes of periphery contracts:

1. **Strategy proxies** — `TransparentUpgradeableProxy` instances (ERC-1967) whose `ProxyAdmin` is owned by the factory. The factory registers approved implementations by their `IContractId.ID()`, enforces a whitelist of valid upgrade paths, and acts as the on-chain upgrader.

2. **PMH clones** — Non-upgradeable ClonesWithImmutableArgs clones of `PositionHelperBase` implementations. The factory registers approved implementations by their `IContractId.ID()` and handles 62-byte immutable arg encoding automatically.

3. **Hook clones** — Non-upgradeable ClonesWithImmutableArgs clones of hook implementations (e.g. `HookContainer`, `UserDepositCapHook`, `DepositLockHook`). The factory registers approved implementations by their `IContractId.ID()` and embeds a 40-byte immutable-arg payload — `[factory (20)][vault (20)]` — into each clone, read back via `VAULT()` / `FACTORY()`. The embedded factory address lets each hook gate its `initialize(...)` to the factory; hook-specific configuration (owner/admin and parameters) is supplied through the forwarded `initData`.

All three registries are independent. A single factory instance manages all of them.

---

## Architecture

### Upgradeability

`PeripheryFactory` is itself a UUPS proxy. The owner controls `_authorizeUpgrade`, ensuring only the owner can push a new factory implementation. State is stored via EIP-7201 (`PeripheryFactoryStorageLib`) to prevent storage collisions across upgrades.

### Access model

The factory has an **owner** and a **factory manager** (set by the owner via `setFactoryManager`).

- Factory manager: `approveStrategyImpl`, `approvePMHImpl`, `approveHookImpl`, `setStrategyMigratable` (all timelocked via `afterDelay`), and `blockStrategyImpl`, `blockPMHImpl`, `blockHookImpl`, `unsetStrategyMigratable`, `registerStrategy`, `pause` (instant).
- Owner: `unblockStrategyImpl`, `unblockPMHImpl`, `unblockHookImpl`, `unpause`, `setTimelock`, `transferOwnership` (all timelocked), `activateTimelock`, `setFactoryManager` and factory upgrades.

Timelocked functions only take effect after their delay once a timelock is set and activated (see `Timelock.md`).

Deployment functions (`deployStrategy`, `clonePMH`, `cloneHook`) and upgrade functions (`upgradeStrategy`, `batchUpgradeStrategies`) are permissionless — any caller may invoke them while the factory is not paused, but:
- `deployStrategy` requires the target `implId` to be approved and unblocked.
- `upgradeStrategy` additionally requires the caller to hold `STRATEGY_ADMIN` or `STRATEGY_UPGRADER` on the strategy proxy being upgraded.

### Strategy upgrade role flow

When `deployStrategy(implId, initData)` is called:
1. The factory creates `new TransparentUpgradeableProxy(impl, address(this), initData)`.
2. The factory becomes the owner of the proxy's `ProxyAdmin`, giving it exclusive authority to call `ProxyAdmin.upgradeAndCall`.
3. Because the factory is `msg.sender` during proxy construction, the strategy's `initialize(...)` grants `STRATEGY_UPGRADER` to the factory and `STRATEGY_ADMIN` to the `admin` parameter.

When `upgradeStrategy(proxy, newImplId, data)` is called:
1. Factory checks the caller holds `STRATEGY_ADMIN` or `STRATEGY_UPGRADER` on `proxy`.
2. Factory validates the migration path is whitelisted via `setStrategyMigratable`.
3. Factory calls `ProxyAdmin.upgradeAndCall(proxy, newImpl, data)` using its ProxyAdmin ownership.

### PMH clone encoding

`clonePMH` reads `IERC20Metadata(token).decimals()` on-chain and assembles the 62-byte payload:

```
abi.encodePacked(positionOwner, collateralToken, borrowToken, collateralDecimals, borrowDecimals)
```

The clone is created via `ClonesWithImmutableArgs.clone(impl, immutableArgs)`. If `initData` is non-empty, the factory makes a low-level call to `clone.call(initData)` and bubbles any revert.

---

## EIP-7201 Storage (`PFStorage`)

Stored at `keccak256(abi.encode(uint256(keccak256("concrete.storage.PeripheryFactoryStorage")) - 1)) & ~bytes32(0xff)`.

### Strategy registry

| Field | Type | Description |
|---|---|---|
| `strategyImpls` | `mapping(uint64 → address)` | implId → approved strategy implementation address |
| `strategyBlocked` | `mapping(uint64 → bool)` | implId → blocked from further deployment/upgrade |
| `strategyMigratable` | `mapping(uint64 → mapping(uint64 → bool))` | fromImplId → toImplId → migration allowed |
| `strategies` | `mapping(address → bool)` | proxy address → deployed by this factory |

### PMH clone registry

| Field | Type | Description |
|---|---|---|
| `pmhImpls` | `mapping(uint64 → address)` | implId → approved PMH implementation address |
| `pmhBlocked` | `mapping(uint64 → bool)` | implId → blocked from further cloning |
| `pmhClones` | `mapping(address → bool)` | clone address → cloned by this factory |

### Hook clone registry

| Field | Type | Description |
|---|---|---|
| `hookImpls` | `mapping(uint64 → address)` | implId → approved hook implementation address |
| `hookBlocked` | `mapping(uint64 → bool)` | implId → blocked from further cloning |
| `hookClones` | `mapping(address → bool)` | clone address → cloned by this factory |

---

## Function Reference

### Initializer

#### `initialize(address owner_, address timelock_)`
Sets the initial owner and the timelock (`address(0)` for none). Called once on the proxy at deployment.

---

### Strategy — Registration

#### `approveStrategyImpl(address implementation)` — `onlyFactoryManager`, timelocked
Reads `IContractId(implementation).ID()` and stores `strategyImpls[id] = implementation`.

Reverts:
- `ZeroAddress` — if implementation is `address(0)`.
- `ZeroImplId` — if `ID()` returns 0.
- `ImplAlreadyApproved` — if the ID is already registered.

#### `blockStrategyImpl(uint64 implId)` — `onlyFactoryManager`
Marks `strategyBlocked[implId] = true`. Further `deployStrategy` and `upgradeStrategy` calls targeting this ID will revert.

Reverts:
- `ImplNotFound` — if not registered.
- `AlreadyBlocked` — if already blocked.

#### `setStrategyMigratable(uint64 fromImplId, uint64 toImplId)` — `onlyFactoryManager`, timelocked
Permits upgrading proxies running `fromImplId` to `toImplId`.

Reverts:
- `SameImpl` — if IDs are equal.
- `ImplNotFound` — if either ID is not registered.

---

### Strategy — Deployment

#### `deployStrategy(uint64 implId, bytes calldata initData) → address proxy`
Deploys an ERC-1967 proxy backed by `strategyImpls[implId]` and calls `proxy.call(initData)` (via the proxy constructor). Registers the proxy in `strategies`.

Reverts:
- `ImplNotFound` — if not registered.
- `ImplBlocked` — if blocked.

> `initData` should encode the strategy's `initialize(...)` call. The factory is `msg.sender` during construction and receives `STRATEGY_UPGRADER`; the `admin` parameter receives `STRATEGY_ADMIN` and `ROLE_ADMIN`.

#### `upgradeStrategy(address proxy, uint64 newImplId, bytes calldata data)`
Upgrades a registered strategy proxy to a new implementation. Caller must hold `STRATEGY_ADMIN` or `STRATEGY_UPGRADER` on `proxy`.

Reverts:
- `NotRegistered` — proxy not in `strategies`.
- `NotStrategyUpgrader` — caller lacks both `STRATEGY_ADMIN` and `STRATEGY_UPGRADER`.
- `SameImpl` — current and new IDs are the same.
- `CanNotMigrate` — migration not whitelisted.
- `ImplNotFound` — new implementation not registered.
- `ImplBlocked` — new implementation is blocked.

#### `batchUpgradeStrategies(address[] calldata proxies, uint64 newImplId, bytes[] calldata data)`
Iterates `proxies` and calls `_upgradeStrategy` for each. `proxies` and `data` must have equal length.

Reverts:
- `InvalidDataLength` — length mismatch.
- Any error from `_upgradeStrategy` for an individual proxy.

---

### Strategy — Views

| Function | Returns |
|---|---|
| `getStrategyImpl(uint64 implId)` | Implementation address (0 = not registered) |
| `isStrategyImplBlocked(uint64 implId)` | Whether blocked |
| `isStrategyMigratable(uint64 from, uint64 to)` | Whether upgrade path is open |
| `isRegisteredStrategy(address proxy)` | Whether deployed by this factory |

---

### PMH Clone — Registration

#### `approvePMHImpl(address implementation)` — `onlyFactoryManager`, timelocked
Reads `IContractId(implementation).ID()` and stores `pmhImpls[id] = implementation`.

Reverts:
- `ZeroAddress`, `ZeroImplId`, `ImplAlreadyApproved` (same semantics as strategy side).

#### `blockPMHImpl(uint64 implId)` — `onlyFactoryManager`
Marks `pmhBlocked[implId] = true`. Further `clonePMH` calls targeting this ID will revert.

Reverts:
- `ImplNotFound`, `AlreadyBlocked`.

---

### PMH Clone — Deployment

#### `clonePMH(uint64 implId, address positionOwner, address collateralToken, address borrowToken, bytes calldata initData) → address clone_`

Reads `IERC20Metadata` decimals for both tokens, encodes the 62-byte immutable arg payload, and clones the registered implementation. If `initData.length > 0`, forwards the call to `clone_.call(initData)` and bubbles any revert. Registers the clone in `pmhClones`.

Reverts:
- `ZeroAddress` — any of positionOwner, collateralToken, borrowToken is zero.
- `ImplNotFound` — implId not registered.
- `ImplBlocked` — implId is blocked.
- Bubbles clone initializer reverts.

---

### PMH Clone — Views

| Function | Returns |
|---|---|
| `getPMHImpl(uint64 implId)` | Implementation address (0 = not registered) |
| `isPMHImplBlocked(uint64 implId)` | Whether blocked |
| `isRegisteredPMHClone(address clone_)` | Whether cloned by this factory |

---

### Hook Clone — Registration

#### `approveHookImpl(address implementation)` — `onlyFactoryManager`, timelocked
Reads `IContractId(implementation).ID()` and stores `hookImpls[id] = implementation`.

Reverts:
- `ZeroAddress`, `ZeroImplId`, `ImplAlreadyApproved` (same semantics as strategy side).

#### `blockHookImpl(uint64 implId)` — `onlyFactoryManager`
Marks `hookBlocked[implId] = true`. Further `cloneHook` calls targeting this ID will revert.

Reverts:
- `ImplNotFound`, `AlreadyBlocked`.

---

### Hook Clone — Deployment

#### `cloneHook(uint64 implId, address vault_, bytes calldata initData) → address clone_`

Clones the registered implementation as a ClonesWithImmutableArgs minimal proxy, appending `[factory (20)][vault (20)]` (`abi.encodePacked(address(this), vault_)`) as immutable args, then forwards `initData` to `clone_.call(initData)`, bubbling any revert. Registers the clone in `hookClones`. The embedded factory address lets each hook gate its `initialize(...)` to the factory (reverting with `NotFactory` otherwise), closing the clone-initialization front-running window. The vault is read on-chain via `VAULT()`; the remaining hook configuration (owner/admin and hook-specific parameters) is supplied through `initData`. Reverts with `ZeroAddress` if `vault_ == address(0)`.

Reverts:
- `ImplNotFound` — implId not registered.
- `ImplBlocked` — implId is blocked.
- `InvalidInitData` — `initData` is empty.
- Bubbles clone initializer reverts.

---

### Hook Clone — Views

| Function | Returns |
|---|---|
| `getHookImpl(uint64 implId)` | Implementation address (0 = not registered) |
| `isHookImplBlocked(uint64 implId)` | Whether blocked |
| `isRegisteredHookClone(address clone_)` | Whether cloned by this factory |

### Administration

| Function | Caller | Notes |
|---|---|---|
| `unblockStrategyImpl` / `unblockPMHImpl` / `unblockHookImpl(uint64 implId)` | owner | timelocked |
| `unsetStrategyMigratable(uint64 fromImplId, uint64 toImplId)` | factory manager | instant |
| `registerStrategy(address proxy, address proxyAdmin)` | factory manager | brings an externally-deployed proxy under the factory |
| `deregisterStrategy(address proxy, address newOwner)` | owner or the strategy's `STRATEGY_ADMIN` | removes the proxy and hands over `ProxyAdmin` ownership |
| `pause()` / `unpause()` | factory manager / owner | pause stops deployments and upgrades; unpause is timelocked |
| `setFactoryManager(address manager)` | owner | |
| `setTimelock(address)` / `activateTimelock()` | owner | `setTimelock` is timelocked |

---

## Events

### Strategy events

| Event | Emitted when |
|---|---|
| `StrategyImplApproved(implId, implementation)` | `approveStrategyImpl` succeeds |
| `StrategyImplBlocked(implId)` | `blockStrategyImpl` succeeds |
| `StrategyMigratableSet(fromImplId, toImplId)` | `setStrategyMigratable` succeeds |
| `StrategyDeployed(proxy, implId)` | `deployStrategy` succeeds |
| `StrategyUpgraded(proxy, newImplId)` | `_upgradeStrategy` succeeds |

### PMH events

| Event | Emitted when |
|---|---|
| `PMHImplApproved(implId, implementation)` | `approvePMHImpl` succeeds |
| `PMHImplBlocked(implId)` | `blockPMHImpl` succeeds |
| `PMHCloned(clone, implId, positionOwner)` | `clonePMH` succeeds |

### Hook events

| Event | Emitted when |
|---|---|
| `HookImplApproved(implId, implementation)` | `approveHookImpl` succeeds |
| `HookImplBlocked(implId)` | `blockHookImpl` succeeds |
| `HookCloned(clone, implId)` | `cloneHook` succeeds |

---

## Error Reference

| Error | Cause |
|---|---|
| `ZeroAddress` | Supplied address argument is `address(0)` |
| `ZeroImplId` | Implementation's `ID()` returned 0 |
| `ImplAlreadyApproved` | `implId` already has a registered implementation |
| `ImplNotFound` | `implId` is not registered |
| `ImplBlocked` | `implId` is blocked |
| `AlreadyBlocked` | Attempted to block an already-blocked ID |
| `NotRegistered` | Proxy address is not in the factory's strategy registry |
| `NotStrategyUpgrader` | Upgrade caller lacks both `STRATEGY_ADMIN` and `STRATEGY_UPGRADER` on the target proxy |
| `SameImpl` | `fromImplId == toImplId` in `setStrategyMigratable` or `upgradeStrategy` |
| `CanNotMigrate` | Upgrade path not whitelisted via `setStrategyMigratable` |
| `InvalidDataLength` | `proxies.length != data.length` in `batchUpgradeStrategies` |
| `InvalidInitData` | `initData` is empty in `deployStrategy`, `clonePMH`, or `cloneHook` |

---

## Security considerations

### Blocking is instant, unblocking is timelocked
`blockStrategyImpl` / `blockPMHImpl` / `blockHookImpl` take effect immediately. A blocked ID can only be re-activated by the owner via `unblockStrategyImpl` / `unblockPMHImpl` / `unblockHookImpl`, which are timelocked. This keeps a known-bad implementation from being re-activated without notice.

### Factory owns ProxyAdmin for upgrades
The factory's ability to execute proxy upgrades depends on it being the owner of the ProxyAdmin deployed alongside each strategy proxy. When `deployStrategy` is used, this ownership is established automatically. When `registerStrategy` is used for externally-deployed proxies, ProxyAdmin ownership must be transferred to the factory beforehand.

### Migration whitelist prevents unsolicited upgrades
`upgradeStrategy` requires both a caller role (`STRATEGY_ADMIN` or `STRATEGY_UPGRADER`) AND an explicit `setStrategyMigratable` entry for the `(from, to)` pair. Neither alone is sufficient. This double-gate prevents a rogue admin from pushing unapproved implementations.

### Clone initializer failure bubbles
If the initializer call after cloning reverts, the entire `clonePMH` transaction reverts. The clone is NOT registered in `pmhClones`. This prevents half-initialised clones.

### Registry cleanup
There is no `removeStrategyImpl` or `removePMHImpl`. Removal of an implementation is expressed as blocking; the implementation registries and `pmhClones` are append-only. A deployed strategy can leave the factory via `deregisterStrategy(proxy, newOwner)` (owner or the strategy's `STRATEGY_ADMIN`): it is removed from `strategies` and its `ProxyAdmin` ownership moves to `newOwner`.
