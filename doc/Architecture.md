# Concrete Earn V2 Architecture
## Overview 

Concrete V2 is a protocol for aggregating yield and allows curators to deploy vaults permissionlessly. As such it comprises three main components: Vaults of various flavour, a factory for vault deployments and peripherial infrastructure that complement the core features such as bespoke strategies, hooks, fee splitters and other auxiliary contracts. Privileged calls on vaults, factories, strategies and the oracle module can be delayed through a shared timelock (see [Section 3.8](#38-timelock)).

## Table of Contents

🏭 **[1. Factory](#1-factory)**
- 1.1. Vault Deployment
- 1.2. Implementation and Vault Registry  
- 1.3. Upgrade Vaults
- 1.4. Factory Administration

🏦 **[2. Concrete V2 Vaults](#2-concrete-v2-vaults)**
- 2.1. Main User Operations
- 2.2. Vault Accounting
- 2.3. Yield Accrual
- 2.4. Fees
- 2.5. Access Control And Vault Operations
  - 2.5.8. Halted Strategies
- 2.6. Concrete Vault Implementations
  - 2.6.1. Asynchronous Vault Overview
  - 2.6.2. Access Control and Events
  - 2.6.3. Async Vault Initialization
  - 2.6.4. Predeposit and Bridged Vaults
  - 2.6.5. Multi-Asset Deposit Vault

🔧 **[3. Peripheral Contracts](#3-peripheral-contracts)**
- 3.1. Strategies
  - 3.1.1. Base Strategy Interface
  - 3.1.2. Allocator Fund Movement
  - 3.1.3. Multisig Strategies
  - 3.1.4. Simple and Multi-Asset Strategies
  - 3.1.5. Looping Strategies
- 3.2. Hooks
- 3.3. Fee Splitter
- 3.4. Fee Accountant
- 3.5. Asset Pricers and Oracle Module
- 3.6. Position Helpers
- 3.7. Periphery Factory
- 3.8. Timelock


## 1. Factory

The factory is an upgradeable contract that has the following three major functionalities:  
1) deploy vaults
2) register implementations and vaults
3) upgrade vaults

**Factory Architecture:**
- **Upgradeability**: Uses the UUPS (Universal Upgradeable Proxy Standard) proxy pattern for upgradeability
- **Upgrade Control**: Only the factory owner can upgrade the factory implementation
- **Storage Layout**: Implements EIP-7201 storage layout pattern for upgradeable contracts
- **Location**: Factory contracts are located in `src/factory/` directory

### 1.1. Vault Deployment

The deployment of vaults works as follows. The deployer can choose from one of several implementations. Implementations are vault contracts of a certain flavor and with certain unique features, that have been registered in the factory. The deployment of a vault is done via the function 
```js
function create(uint64 vaultImpl, address ownerAddr, bytes calldata data, bytes32 salt) external returns (address)
```
It is a permissionless function with four arguments. The `vaultImpl` is the unique identifier of the implementation (see [Section 1.1.1](#111-vault-id-and-versioning-system) for details), the `ownerAddr` is the admin of the vault (see [Section 2.5](#25-access-control-and-vault-operations)), the `data` carries some initialization data and the `salt` allows to create predictable deterministic vault addresses. An overload without `salt` exists as well. Upon deployment an ERC-1967 proxy is created that points to the logic of the registered implementations. Upon successful deployment the following event will be emitted:
```js
event Deployed(address indexed vault, uint64 indexed vaultImpl, address indexed owner); 
``` 
If there is no such vault ID or the vault ID has been blocked, then the call will revert. A useful function for curators to predict their vault addresses is:
```js 
function predictVaultAddress(uint64 vaultImpl, address ownerAddr, bytes calldata data, bytes32 salt)
```

#### 1.1.1. Vault ID and Versioning System

Concrete V2 uses a dual versioning system that decouples contract identification from OpenZeppelin's Initializable versioning:

**Vault IDs (Contract IDs):**
- **Source of Truth**: Vault implementations define their own unique `vaultImpl` through a hardcoded `ID()` function (a virtual pure function that can be overridden by inheriting contracts)
- **Queryable**: Vault IDs can be queried directly from implementations via `IContractId(implementation).ID()`
- **Consistent Across Chains**: The same implementation will have the same vault ID across all execution environments/chains
- **Encoding**: An ID encodes the contract type, the flavour and the version (`ContractIdEncoding`)
- **Semantic Separation**: Vault IDs are semantically distinct from OpenZeppelin's Initializable versioning system

**OpenZeppelin Initializable Versioning:**
- **Separate System**: Uses OpenZeppelin's `Initializable._initialized` storage variable to track upgrade iterations
- **Upgrade Tracking**: Each upgrade increments the initialized version independently of vault IDs

**Factory Registry:**
- **Registry Role**: The factory acts as a registry that maps vault IDs to implementations via `mapping(uint64 => address) vaultImplToImplementation`
- **Not Source of Truth**: The implementation defines its ID; the factory only maintains the registry of approved implementations

**Benefits:**
- **Queryability**: Vault IDs can be queried from implementations without factory interaction
- **Cross-Chain Consistency**: Same implementation = same ID across all chains
- **Semantic Clarity**: Clear separation between contract identity (vault ID) and upgrade iteration (OZ version)

### 1.2. Implementation and Vault Registry

New implementations are approved or blocked by the **factory manager** (see [Section 1.4](#14-factory-administration)) via the following two functions. Approval is timelocked, blocking is instant.
```js
function approveImplementation(address implementation) external onlyFactoryManager afterDelay;
function blockImplementation(uint64 vaultImpl) external onlyFactoryManager;
```
They will respectively emit the following events:
```js
event ApprovedImplementation(address indexed implementation);
event NewVaultImplToImplementation(uint64 indexed vaultImpl, address indexed implementation);
event Blocked(uint64 indexed vaultImpl);
```
A blocked implementation can be unblocked by the factory owner through `unblockImplementation(uint64 vaultImpl)` (timelocked, emits `Unblocked`). There is also `blockImplementationByAddress(address implementation)`.

When approving an implementation, the factory:
1. Queries the implementation's vault ID via `IContractId(implementation).ID()`
2. Registers the mapping from vault ID to implementation address
3. Emits both `ApprovedImplementation` and `NewVaultImplToImplementation` events

Only approved implementations can be deployed. The factory maintains a registry mapping vault IDs to implementations:
```js
mapping(uint64 => address) vaultImplToImplementation
```

**Querying Implementations:**
```js 
function getImplementationByVaultImpl(uint64 vaultImpl) public view returns (address)
function isBlocked(uint64 vaultImpl) public view returns (bool)
```

Regarding the vault registry, it is simply a mapping `mapping(address => bool) vaults;`. There are two ways how vaults can be registered. 
1) Deploy a vault through the factory (see above)
2) Register a vault deployed not through the factory

The default scenario is that a vault gets deployed through the factory. The alternative path is to register it via the following function (emits `VaultRegistered`)
```js
function registerVault(address vault) external onlyFactoryManager
```

One may query the factory about registered vaults via:
```js
function isRegisteredVault(address vault) public view returns (bool)
```

### 1.3. Upgrade Vaults

Deployed vaults may be upgraded. Upgrading means that the implementation of the proxy is changed and re-initialized. However not any implementation can be chosen for the upgrade. The implementation must be approved, non-blocked and migrateable. 

**Migratability:**
Migratability is a feature that can be set for any pair of implementations. Setting a migration path is done by the factory manager and is timelocked. Removing one (`unsetMigratable`) is instant, since closing a wrongly-opened path is a restrictive correction.
```js 
function setMigratable(uint64 fromVaultImpl, uint64 toVaultImpl) external onlyFactoryManager afterDelay
function unsetMigratable(uint64 fromVaultImpl, uint64 toVaultImpl) external onlyFactoryManager
```
One may query the migratability:
```js 
function isMigratable(uint64 fromVaultImpl, uint64 toVaultImpl) public view returns (bool)
```

**Upgrade Process:**
In order to upgrade a particular vault to a new vault ID, the vault owner has to call:
```js
function upgrade(address vault, uint64 newVaultImpl, bytes calldata data) external
```
on the factory. `batchUpgrade(address[] vaults, uint64 newVaultImpl, bytes[] data)` upgrades several vaults of the same owner in one call. Both revert while the factory is paused. The factory will:
1. Determine the current vault ID of the vault being upgraded
2. Validate that the caller is the vault owner and that the upgrade is allowed (approved, non-blocked, and migratable)
3. Call the vault's upgrade function with both the old and new vault IDs

**Vault Upgrade Function:**
The vault's upgrade function receives both the old and new vault IDs:
```js
function upgrade(uint64 oldVaultImpl, uint64 newVaultImpl, bytes calldata data) external
```
The vault does not store its own previous ID, so the factory passes it in. This lets the vault validate and handle the upgrade.

A successful upgrade requires the abovementioned guards on the approval, blockage and migratability of source and target implementation to be passed. It then emits the following event:
```js
event Migrated(address indexed vault, uint64 newVaultImpl);
```

### 1.4. Factory Administration

The factory has two privileged accounts:
- **Factory owner**: upgrades the factory, unblocks implementations, unpauses, sets the default fee recipients, sets the factory manager and manages the timelock. Ownership transfer is timelocked.
- **Factory manager**: approves and blocks implementations, sets and unsets migration paths, registers vaults and pauses the factory. Set by the owner via `setFactoryManager(address)` (emits `FactoryManagerSet`).

**Pausing:** `pause()` (factory manager) stops vault upgrades. `unpause()` is reserved for the owner and is timelocked.

**Default fee recipients:** The factory owner sets the management and performance fee recipients that every new vault starts with (timelocked):
```js
function setDefaultEnforcedVaultConfiguration(address managementFeeRecipient, address performanceFeeRecipient)
```
It emits `DefaultEnforcedVaultConfigurationUpdated`. Later changes on a single vault go through the vault (see [Section 2.5.1](#251-vault-functions-guarded-by-factory-owner)).

**Timelock:** `setTimelock(address)` (timelocked) and `activateTimelock()` connect the factory to the shared timelock (see [Section 3.8](#38-timelock)). Functions marked `afterDelay` above only take effect after their delay once the timelock is active.


## 2. Concrete V2 Vaults

The Concrete V2 Vaults are ERC4626-vaults. They adhere to the standard in all but one place, which regards the reporting of totalAssets. This will be covered in [Section 2.3](#23-yield-accrual). These vaults are single-asset vaults in the sense that they take one asset type under management. The only exception is the multi-asset deposit vault (see [Section 2.6.5](#265-multi-asset-deposit-vault)), which accepts further deposit tokens but still accounts in its base asset. They allow users to deposit and withdraw and the accounting on the vault level works through an ERC20 token whose balance tracks the holders share of the vault.

**Vault Architecture:**
- **Storage Layout**: Implements EIP-7201 storage layout pattern for upgradeable contracts
- **Storage Management**: Storage and utilities are handled through dedicated libraries
- **Library Structure**: Core functionality is organized in libraries located in `src/lib/` directory
- **Upgradeability**: Vaults are upgradeable through the factory's upgrade mechanism via `UpgradeableVault` base contract (`src/common/UpgradeableVault.sol`)
- **Location**: Vault implementations are located in `src/implementation/` directory 

The vaults can hold several strategies, which are adapters to other protocols or abstract away functions and features to earn yield. Hence the name __Multi-Strategy-Vault__. Accounting of totalAssets happens through a cached variable, rather than a query of `balanceOf`. All vaults are capable of charging various fee types. By default the vaults come with two fee types, which are the management and performance fees.

### 2.1. Main User Operations

For the user operations all vaults expose four main entrypoints:
```js
function deposit(uint256 assets, address receiver) external returns (uint256 shares);
function mint(uint256 shares, address receiver) external returns (uint256 assets);
function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
```
Deposit and Mint allow users to deposit funds into the vault. Those funds need to be of that asset type. They differ in the input and output arguments. Deposit allows the user to pass in the amount that they wish to deposit and returns the amount of minted accounting tokens, also called shares. Mint allows users to pass the amount of shares they wish to mint and returns the amount of assets deposited. Both functions require the holder to approve the vault to spend its tokens. Withdraw and Redeem allow users to withdraw from the vault. They differ again with respect to the input arguments. The former takes the amount of assets and returns the amount of redeemed shares. The latter takes in the amount of shares to be redeemed and returns the asset withdrawn. For each of these functions a different receiver can be designated. Withdrawal and redemption can also happen on behalf of the owner if the approvals are correct. All four revert while the vault is paused.

In Concrete V1 each of these entrypoints had an additional entrypoint for the default case where the receiver equals the `msg.sender`. But in Concrete V2 those additional functions have been omitted.

Each of the user operations has a preview[userOP] and a max[userOP] function. These can be used to preview the shares minted during deposit, the amount deposited during a mint, the redemption amount during a withdraw and the withdrawal amount during a redemption. 

```js 
function previewDeposit(uint256 assets) external view returns (uint256 shares);
function previewMint(uint256 shares) external view returns (uint256 assets);
function previewWithdraw(uint256 assets) external view returns (uint256 shares);
function previewRedeem(uint256 shares) external view returns (uint256 assets);
```

### 2.2. Vault Accounting 

As mentioned above the vault accounting happens through a designated ERC20-token, the vault share. In fact the vault itself is an ERC20 token. There are two values around which most of the accounting is constructed: 1) `totalAssets` and 2) `totalSupply`. The first one is the amount of assets under management and the second one is the amount of shares issued in total. The share worth in asset terms is usually something like the ratio of the two (see below). 

One important feature of the Concrete-V2 vaults is that `totalAssets` is in fact a state variable at the vault. This has two benefits and one draw-back. First of all it safe-guards against donation-attacks, such as the inflation attack. If assets were tracked trough `balanceOf` reporting, they could be manipulated without interacting with the vault, simply by donating to the vault. Second, the gas-costs of multi-strategy vaults typically scale with the amount of strategies. If the total asset reporting were to query each strategy each time it is called, the gas costs would scale unfavourably. Hence a caching can help with that. It does however also mean that the cached variable always needs to be kept up to date. Tokens donated to the vault are not counted and can be swept by the vault manager via `sweepDonatedTokens(address token, address recipient)`.

Every ERC4626 vault has two functions that allow the conversion of assets and shares and vice versa:
```js
function convertToAssets(uint256 shares) external view returns (uint256 assets);
function convertToShares(uint256 assets) external view returns (uint256 shares);
```
In the case of the Concrete-V2 vaults these conversions are defined as follows:
```latex
assets = Floor [shares * (totalAssets + 1) / (totalSupply + 1)]
shares = Floor [assets * (totalSupply + 1) / (totalAssets + 1)]
```
**NOTE**: It is note-worthy that the totalAsset cached value is updated prior to the calculation. In general each user or operator intervention requires the updating of totalAssets.

### 2.3. Yield Accrual

In order to keep an up-to-date quote of the total Assets, the yield generated by the strategies and the fees (see below) has to be accurately accounted for. To this end there are three internal functions called `_accrueYield()`, `_previewAccrueYieldAndFees()` and `_previewYieldNoFees()`. Before any user or administrative operations the cached value of total Assets is updated by calling the accrue yield internal function. This happens through the modifier `modifier withYieldAccrual()`. The allocator can also trigger it directly through `function accrueYield() external`.

One consequence of this accounting method is the existence of two functions that report totalAssets, namely one that returns the current up-to-date value including yield or loss, which is the `totalAsset()` function that also exists in the ERC4626-standard. The other is the `function cachedTotalAssets() public view returns (uint256)`, which returns merely the state-variable.

Accrual of yield emits several events. First of all each strategy separately emits 
```js
event StrategyYieldAccrued(address indexed strategy, uint256 currentTotalAllocatedValue, uint256 yield, uint256 loss);
```
and then the totality assets lost and gained is tracked in this event
```js 
event YieldAccrued(uint256 totalPositiveYield, uint256 totalNegativeYield);
```
Moreover if fees are accrueing, then fee accrual events will also be emitted.

**IMPORTANT**: The Concrete-V2 vaults are ERC4626-compliant in every point except one, which regards the quote of totalAssets. In case of a broken strategy, where accurate accounting cannot be guaranteed, the value of totalAssets must not reflect a wrong value. Instead totalAssets will revert, which is not compliant to the standard. A halted strategy is skipped instead (see [Section 2.5.8](#258-halted-strategies)).

### 2.4 Fees

Concrete-V2 comes with the ability to charge fees. By default Concrete charges two types of fees: `management fee` and `performance fee`. 

The management fee is charged per annum. Each time the management fee accrues it is checked how much time has elapsed since the previous accrual and based on a state-variable called `uint16 managementFee` which is given in basis points (100% = 10000) the fee is charged accordingly. The fee is charged by minting shares and thus is socialized across all holders. It also leads to a tiny depreciation of the share value.

The performance fee is charged on each positive yield accrual with respect to that yield. This differs from Concrete-V1, where previously the fee has been charged with respect to the share value. In V2 any time the accrual is called and the net effect of the gains and losses across all strategies is positive, a percentage of `uint16 performanceFee` (in basispoints) from that net-yield is deducted. The fee is then minted in shares. However these shares typically do not depreciate the share value, since they are backed by newly accounted assets from the incoming yield. 

**Hurdle rate:** A vault can optionally set a hurdle rate oracle. The performance fee then only applies to yield above the minimum share price that the oracle reports. Three oracles are provided in `src/oracle/`: `APRRateHurdleOracle`, `APYRateHurdleOracle` and `OffchainHurdleRateOracle` (rate pushed by a keeper). See [HurdleRatePerformanceFee](./spec/HurdleRatePerformanceFee.md).

There is no external function that calls the accrual of fees by themselves. It happens in conjunction with the yield accrual, which is at least for the performance fee a pre-requisite for the accrual. The events that are triggered upon successful fee accrual for the management and performance fees are 
```js
event ManagementFeeAccrued(address indexed recipient, uint256 shares, uint256 feeAmount);
event PerformanceFeeAccrued(address indexed recipient, uint256 shares, uint256 feeAmount);
```

There is one fee recipient per fee type. This allows the vault operators to disentangle the fee types. New vaults start with the default recipients set in the factory (see [Section 1.4](#14-factory-administration)). The fee recipient can either be an EOA, an account abstraction or some auxiliary contract that handles the fee processing or splitting. Concrete provides an out-of-the box basic fee-splitter that can divide the fees for up to two parties. It can be found in __src/periphery/auxiliary/TwoWayFeeSplitter.sol__ . If it is set as a fee recipient, the fees will accumulate there and can be distributed on regular intervals. The Two-Way Fee Splitter can also function as a fee splitter for many vaults. It discerns the fees by the token address, which is identical to the vault address for Concrete-v2 ERC4626 vaults. Alternatively the `FeeAccountant` distributes fee shares to several whitelisted recipients (see [Section 3.4](#34-fee-accountant)).

In summary the fees are handled as follows:

1. Concrete-V2 charges two types of fees by default: management fee and performance fee.
2. All fees are minted as shares to a recipient.
3. Management fees are calculated per annum on every user and operator interaction.
4. Performance Fees are taken directly from the generated yield (major change from previous v1).
5. The performance fee can be gated by a hurdle rate. There is no high water mark. 
6. Fee calculation is global, not at user level. 

### 2.5. Access Control And Vault Operations

The Concrete-V2 vaults have three different modes of access control and permissions: factory ownership, vault ownership and a role-based access. Every vault has an owner, who may upgrade the vault to another version. This role may be called `upgrade admin`. It uses the Openzeppelin `Ownable` model (or the upgradeable version of it). The current imcumbant can be queried via the `owner()` public function. For the common vault operations there are five roles set aside: 1) Vault Manager 2) Strategy Manager 3) Hook Manager 4) Allocator 5) Pauser. The Vault Manager is used for updating state variable. The Strategy Manager can add, remove or halt strategies (see below in [Section 3.1](#31-strategies)). The hook Manager can set and update the hook (See [Section 3.2](#32-hooks)). The Allocator can allocate funds to strategies or deallocate them. They can also set a de-allocation order (see [Section 3.1.2](#312-allocator-fund-movement)). The Pauser can pause the vault.

The role-based access control uses the OpenZeppelin `AccessControlUpgradeable` contracts, where each Role has an admin role. Account with that role can grant and revoke the underlying role from role-holders. In Concrete-V2 all roles share a single admin role, `ROLE_ADMIN`, which is also its own admin. It is granted to the initial vault manager, whose address is passed into the initialization data. That means that the initial vault manager may assign all the above roles. The last `ROLE_ADMIN` cannot be removed, so a vault cannot lose its role administration. Role definitions are located in `src/lib/Roles.sol`. 

more complex implementations can have additional roles. One of the more common implementation that is used in Concrete-V2 is the AsyncVault Implementation (see [Section 2.6](#26-concrete-vault-implmentations)). It also comes with a `WITHDRAWAL_MANAGER` and a `PRIORITY_WITHDRAWAL_EXECUTOR` role. 

**Timelock:** Functions marked as timelocked below carry the `afterDelay` modifier. Once the vault owner has set and activated a timelock (`setTimelock`, `activateTimelock`), such a call only succeeds after it has been proposed on the timelock and its delay has passed (see [Section 3.8](#38-timelock)). The role check stays in place on top of the delay.

Here we discuss the main state variables and their access guards:

#### 2.5.1 Vault functions guarded by factory owner

| Function | Event | Timelocked |
|----------|-------|------------|
| `vault.updateManagementFeeRecipient(address recipient)` | `ManagementFeeRecipientUpdated(address managementFeeRecipient)` | yes |
| `vault.updatePerformanceFeeRecipient(address recipient)` | `PerformanceFeeRecipientUpdated(address performanceFeeRecipient)` | yes |

#### 2.5.2 Functions guarded by vault owner

| Function | Event | Timelocked |
|----------|-------|------------|
| `factory.upgrade(address vault, uint64 newVaultImpl, bytes calldata data)` | `Migrated(address indexed vault, uint64 newVaultImpl)` | no |
| `vault.setTimelock(address timelock)` | — | yes |
| `vault.activateTimelock()` | — | no |
| `vault.transferOwnership(address newOwner)` | `OwnershipTransferred(address previousOwner, address newOwner)` | yes |

#### 2.5.3 Functions guarded by vault manager

Most vault parameters are set through one timelocked entrypoint:
```js
function configure(VaultManagerConfig configType, bytes calldata data) external
```

| `configType` | `data` | Event |
|----------|-------|-------|
| `ManagementFee` | `uint16 managementFee` | `ManagementFeeUpdated(uint16 managementFee)` |
| `PerformanceFee` | `uint16 performanceFee` | `PerformanceFeeUpdated(uint16 performanceFee)` |
| `HurdleRateOracle` | `address oracle` | `HurdleRateOracleUpdated(address indexed oracle)` |
| `DepositLimits` | deposit limits | `DepositLimitsUpdated(uint256 maxGlobalDepositAmount, uint256 minTxDepositAmount)` |
| `WithdrawLimits` | withdraw limits | `WithdrawLimitsUpdated(uint256 maxTxWithdrawAmount, uint256 minTxWithdrawAmount)` |
| `CancellationEnabled` | `bool enabled` | `CancellationEnabledSet(bool enabled)` (async vaults) |

| Function | Event | Timelocked |
|----------|-------|------------|
| `vault.sweepDonatedTokens(address token, address recipient)` | `DonationSwept(address indexed token, address indexed recipient, uint256 amount)` | no |

#### 2.5.4 Functions guarded by strategy manager

| Function | Event | Timelocked |
|----------|-------|------------|
| `vault.addStrategy(address strategy)` | `StrategyAdded(address strategy)` | yes |
| `vault.removeStrategy(address strategy)` | `StrategyRemoved(address strategy)` | no |
| `vault.toggleStrategyStatus(address strategy)` | `StrategyStatusToggled(address indexed strategy)` | no |
| `vault.reconcileHaltedStrategy(address fromStrategy, address toStrategy)` | `StrategyLossRealized` or `StrategyAllocationMigrated`, then `StrategyRemoved` | no |

#### 2.5.5 Functions guarded by hook manager

| Function | Event | Timelocked |
|----------|-------|------------|
| `vault.setHooks(Hooks memory hooks)` | `HooksSet(Hooks hooks)` | yes |

#### 2.5.6 Functions guarded by allocator

| Function | Event | Timelocked |
|----------|-------|------------|
| `vault.allocate(bytes calldata data)` | `AllocatedFunds(...)` per strategy (see [Section 3.1.2](#312-allocator-fund-movement)) | no |
| `vault.setDeallocationOrder(address[] calldata order)` | `DeallocationOrderUpdated()` | no |
| `vault.accrueYield()` | `YieldAccrued(uint256 totalPositiveYield, uint256 totalNegativeYield)` | no |

#### 2.5.7 Functions guarded by pauser

| Function | Event | Timelocked |
|----------|-------|------------|
| `vault.pause()` | `Paused(address account)` | no |
| `vault.unpause()` | `Unpaused(address account)` | yes |

While paused, user operations, allocation, hook and strategy changes revert. Because unpausing is timelocked, a pause should be used deliberately.

#### 2.5.8 Halted Strategies

`toggleStrategyStatus` switches a strategy between Active and Halted. A halted strategy receives no allocations and is skipped by yield accrual and withdrawals. Its `allocated` amount and `cachedTotalAssets` stay unchanged, so the accounting remains consistent while it is halted.

A halted strategy that still has `allocated > 0` cannot be removed directly. It has to be reconciled first via `reconcileHaltedStrategy(fromStrategy, toStrategy)`:
- `toStrategy == address(0)`: the loss is realized and `cachedTotalAssets` is written down.
- `toStrategy != address(0)`: the position is moved onto an Active strategy.

See [HaltedStrategyHandling](./spec/HaltedStrategyHandling.md) for details.

 
### 2.6. Concrete Vault Implmentations 

Concrete V2 has several implementations (located in `src/implementation/`). Each has its own flavour, which is part of its vault ID:

| Implementation | Flavour | Description |
|----------|-------|-------|
| `ConcreteStandardVaultImpl` | 1 | Synchronous, i.e. atomic, handling of deposits and withdrawals |
| `ConcreteAsyncVaultImpl` | 2 | Asynchronous handling of withdrawals, atomic handling of deposits |
| `ConcretePredepositVaultImpl` | 3 | L1 pre-deposit vault that migrates to an L2 vault (see [Section 2.6.4](#264-predeposit-and-bridged-vaults)) |
| `ConcreteBridgedStandardVaultImpl` | 5 | Standard vault with unbacked minting, used as a migration target |
| `ConcreteBridgedAsyncVaultImpl` | 6 | Async vault with unbacked minting, receives the shares of a predeposit vault on L2 |
| `ConcreteMultiAssetDepositAsyncVault` | 8 | Async vault that also accepts whitelisted non-base deposit tokens (see [Section 2.6.5](#265-multi-asset-deposit-vault)) |

#### 2.6.1. Asynchronous Vault Overview

The asynchronous implementation inherits the standard implementation and only overrides the withdrawal feature. It introduces a queue-based withdrawal system that allows for better liquidity management and batch processing of withdrawal requests. This system operates in epochs and provides several key features:

> **📖 Detailed Specification**: For comprehensive technical details, state machine diagrams, and mathematical specifications of the async vault, see [ConcreteAsyncVaultImpl Specification](./spec/ConcreteAsyncVaultImpl.md).

**Queue Toggle Functionality:**
The async vault can toggle the queue on and off, allowing it to operate in two modes:
- **Queue Active**: Withdrawals are queued in epochs and processed asynchronously
- **Queue Inactive**: The vault operates like a standard implementation with atomic withdrawals

This toggle is controlled by the **Vault Manager** role via the `toggleQueueActive()` function.

**Epoch-Based Processing:**
The queue system operates in discrete epochs, where:
- Each epoch has a unique ID that increments sequentially
- New withdrawal requests are automatically queued in the current epoch
- Closing an epoch (`closeEpoch()`) opens a new one. New incoming requests are then associated to the new epoch.
- Closed epochs can be processed. Which locks a specific share price and makes the funds available for withdrawal.
- An epoch cannot be closed when the previous one hasn't been processed yet. 
- Requests can be claimed individually or in batch for epochs that have been processed.

The life cycle of an epoch is as follows:
Inactive => Active => Processing => Processed.

An epoch is inactive if it is bigger than the current epoch id. 

An epoch is active when its epoch id coincides with the current epoch id. 

An epoch is processing when it has been closed but not processed. Its epoch id is one less than the current one. 

An epoch is processed when it has been closed and processed. Its epoch id is at least one less than the current one.

**Request Lifecycle:**

1) **Request Creation**: Users submit withdrawal requests through the standard `withdraw()` or `redeem()` functions. These requests are automatically queued in the current epoch.

2) **Request Cancellation**: Pending requests can be cancelled for epochs that haven't been processed yet. Users can cancel their own requests via `cancelRequest(uint256 epochID)` if cancellation is enabled on the vault. The **Withdrawal Manager** can cancel on behalf of a user via `cancelRequest(address user, uint256 epochID)`.

3) **Epoch Closing and Processing**: The **Withdrawal Manager** closes the current epoch via `closeEpoch()` and processes the closed epoch via `processEpoch()`. During processing:
   - The current share price is calculated and locked for that epoch
   - Required assets are reserved for the epoch's total withdrawal requests
   - The epoch is marked as processed and ready for claims

4) **Request Rollover**: If needed, (part of) an individual user request can be moved to the next epoch by the **Withdrawal Manager** via `moveRequestToNextEpoch(address user, uint256 fromEpochID, uint256 amount)`.

**Faster paths:**
- **Partial epoch processing**: The Withdrawal Manager can fulfil a single user's request from a closed but not yet processed epoch out of idle funds via `processPartialEpochRequest(address user, uint256 epochID, uint256 amount)`. See [PartialEpochProcessing](./spec/PartialEpochProcessing.md).
- **Priority withdrawal**: The **Priority Withdrawal Executor** can fulfil a pending request right away via `claimPriorityWithdrawal(address user, uint256 sharesToFulfil, uint256 unwindCost, address strategy)`. The user bears the unwind cost, which is capped by the vault's unwind cost cap (`setUnwindCostCap`, vault manager, timelocked). See [PriorityWithdrawal](./spec/PriorityWithdrawal.md).

**Querying Capabilities:**
The async vault provides extensive querying functions for monitoring the queue system:
- `latestEpochID()`: Get the current epoch ID
- `getEpochState(uint256 epochID)`: Get the state of an epoch
- `getUserEpochRequest(address user, uint256 epochID)`: Get a user's request for a specific epoch
- `getUserEpochRequestInAssets(address user, uint256 epochID)`: Get claimable assets for a user's request
- `totalRequestedSharesPerEpoch(uint256 epochID)`: Get total shares requested in an epoch
- `getEpochPricePerShare(uint256 epochID)`: Get the locked share price for a processed epoch
- `pastEpochsUnclaimedAssets()`: Get total assets reserved for past epoch claims
- `isQueueActive()`: Check if the queue is currently active
- `cancellationEnabled()`: Check if users can cancel their own requests

**Batched Withdrawals:**
Withdrawals are processed in batches for efficiency:
- **Individual Claims**: Users can claim their processed withdrawals via `claimWithdrawal(uint256[] calldata epochIDs)`
- **Batch Claims**: The **Withdrawal Manager** can process claims for multiple users in batch via `claimUsersBatch(address[] calldata users, uint256 epochID)`

This batched approach allows for gas-efficient processing of multiple withdrawal claims while maintaining the security and accounting integrity of the vault. 

#### 2.6.2 Access Control and Events

The async vault implementation adds several additional functions that require specific roles. Below are the guarded functions organized by role:

**Functions guarded by VAULT_MANAGER:**

| Function | Event |
|----------|-------|
| `asyncVault.toggleQueueActive()` | `QueueActiveToggled(bool isQueueActive)` |
| `asyncVault.setUnwindCostCap(uint16 unwindCostCap)` (timelocked) | — |

**Functions guarded by WITHDRAWAL_MANAGER:**

| Function | Event |
|----------|-------|
| `asyncVault.closeEpoch()` | `EpochClosed(uint256 epochID)` |
| `asyncVault.processEpoch()` | `EpochProcessed(uint256 epochID, uint256 shares, uint256 assets, uint256 sharePrice)` |
| `asyncVault.processPartialEpochRequest(address user, uint256 epochID, uint256 amount)` | `PartialEpochRequestProcessed(address indexed user, uint256 epochID, uint256 shares, uint256 assets)` |
| `asyncVault.cancelRequest(address user, uint256 epochID)` | `RequestCancelled(address indexed owner, uint256 shares, uint256 epochID)` |
| `asyncVault.claimWithdrawal(address user, uint256[] calldata epochIDs)` | `RequestClaimed(address indexed owner, uint256 assets, uint256[] epochIDs)` |
| `asyncVault.claimUsersBatch(address[] calldata users, uint256 epochID)` | `RequestClaimed(address indexed owner, uint256 assets, uint256[] epochIDs)` |
| `asyncVault.moveRequestToNextEpoch(address user, uint256 fromEpochID, uint256 amount)` | `RequestMovedToNextEpoch(address indexed user, uint256 shares, uint256 currentEpochID, uint256 nextEpochID)` |

**Functions guarded by PRIORITY_WITHDRAWAL_EXECUTOR:**

| Function | Event |
|----------|-------|
| `asyncVault.claimPriorityWithdrawal(address user, uint256 sharesToFulfil, uint256 unwindCost, address strategy)` | `PriorityWithdrawalClaimed(address indexed user, uint256 shares, uint256 grossAssets, uint256 unwindCost, uint256 netAssets, uint256 epochID)` |

**Public Functions (No Access Control Required):**

The following async vault functions are publicly accessible and do not require specific roles:

| Function | Event |
|----------|-------|
| `asyncVault.withdraw(uint256 assets, address receiver, address owner)` | `QueuedWithdrawal(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares, uint256 epochID)` |
| `asyncVault.redeem(uint256 shares, address receiver, address owner)` | `QueuedWithdrawal(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares, uint256 epochID)` |
| `asyncVault.claimWithdrawal(uint256[] calldata epochIDs)` | `RequestClaimed(address indexed owner, uint256 assets, uint256[] epochIDs)` |
| `asyncVault.cancelRequest(uint256 epochID)` (if cancellation is enabled) | `RequestCancelled(address indexed owner, uint256 shares, uint256 epochID)` |

All of these revert while the vault is paused.

**Initialization Event:**

| Function | Event |
|----------|-------|
| Vault initialization | `WithdrawalQueueInitialized(uint256 epochID)` |

#### 2.6.3 Async Vault Initialization

The async vault uses the same initialization arguments as the standard vault implementation since it inherits from `ConcreteStandardVaultImpl`. The initialization data must be ABI-encoded and passed to the factory's `create()` function:

**Required Initialization Arguments:**
```js
abi.encode(
    address allocateModuleAddr,    // Address of the allocation module
    address asset,                 // Address of the underlying asset token
    address initialVaultManager,   // Initial vault manager address (receives ROLE_ADMIN)
    string memory name,           // ERC20 token name for vault shares
    string memory symbol          // ERC20 token symbol for vault shares
)
```

**Initialization Process:**
1. The async vault inherits the standard vault initialization
2. After standard initialization, it calls `__ConcreteAsyncVaultImpl_init()`
3. This sets up the withdrawal queue with:
   - Initial epoch ID set to 1
   - Queue active state set to true
   - Emits `WithdrawalQueueInitialized(1)` event

**Factory Deployment:**
```js
factory.create(
    uint64 vaultImpl,         // Async vault implementation ID
    address ownerAddr,        // Vault owner address
    bytes calldata data,      // ABI-encoded initialization arguments
    bytes32 salt             // Optional salt for deterministic addresses
)
```

#### 2.6.4 Predeposit and Bridged Vaults

A **predeposit vault** (`ConcretePredepositVaultImpl`) on L1 collects deposits for a vault that will live on L2 (or another L1). Withdrawals are disabled from the start and deposits are locked once the migration starts. The assets are bridged, and on L2 a **bridged async vault** (`ConcreteBridgedAsyncVaultImpl`) mints the matching shares once without backing (`unbackedMint`) so the L1 exchange rate is preserved. Users then claim their L2 shares through LayerZero: the L1 shares are burned via `PredepostVaultOApp` and the `ShareDistributor` releases the L2 shares.

`ConcreteBridgedStandardVaultImpl` is the standard-vault counterpart with unbacked minting and serves as a migration target for existing vaults.

See [ConcretePredepositVaultImpl](./spec/ConcretePredepositVaultImpl.md).

#### 2.6.5 Multi-Asset Deposit Vault

`ConcreteMultiAssetDepositAsyncVault` is an async vault that, next to its base asset, accepts whitelisted non-base tokens through an overload:
```js
function deposit(address depositAsset, uint256 assets, address receiver) external returns (uint256 shares);
function previewDeposit(address depositAsset, uint256 assets) external view returns (uint256 shares);
```
Base-asset deposits use the normal ERC-4626 flow. A non-base deposit is valued in base-asset units by the configured asset pricer (see [Section 3.5](#35-asset-pricers-and-oracle-module)), mints shares for that value and is sent straight to the configured `MultiAssetStrategy` (see [Section 3.1.4](#314-simple-and-multi-asset-strategies)). `cachedTotalAssets` and the strategy's `allocated` are credited in base units. Withdrawals are paid out in the base asset only.

**Administration (VAULT_MANAGER):**
- `configureMultiAsset(MultiAssetVaultManagerConfig configType, bytes data)` (timelocked): `AddWhitelistedAsset`, `SetPricer`, `SetMultiAssetStrategy`
- `removeWhitelistedAsset(address asset)`: instant, so a token can be delisted right away

Views: `isWhitelistedAsset`, `getWhitelistedAssets`, `getMultiAssetPricer`, `getMultiAssetStrategy`.

Non-base deposits also trigger the `PRE_DEPOSIT` / `POST_DEPOSIT` hooks and additionally `PRE_MULTI_DEPOSIT` (see [Section 3.2](#32-hooks)).

## 3. Peripheral Contracts

The Concrete V2 protocol includes several peripheral contracts (located in `src/periphery/`) that extend the core vault functionality. These contracts provide additional features such as strategy management, hooks for custom logic, and fee distribution mechanisms.

### 3.1. Strategies

Strategies are external contracts that implement the `IStrategyTemplate` interface and handle fund allocation to different yield-generating protocols or investment opportunities. Each strategy is bound to a single vault and manages that vault's funds in specific protocols.

**Strategy Architecture:**
- **Storage Layout**: Implements EIP-7201 storage layout pattern for upgradeable contracts
- **Proxy Pattern**: Uses transparent proxy pattern for upgradeability. Strategies are deployed and upgraded through the `PeripheryFactory` (see [Section 3.7](#37-periphery-factory))
- **Base Implementation**: All strategies inherit from `BaseStrategy` (`src/periphery/strategies/BaseStrategy.sol`) which provides common functionality
- **Location**: Strategy implementations are located in `src/periphery/strategies/` directory

**Strategy Roles** (`src/periphery/lib/PeripheryRolesLib.sol`): `STRATEGY_ADMIN` (configuration, modules, rescue), `OPERATOR_ROLE` (NAV updates, leverage adjustments), `PAUSER`, `STRATEGY_UPGRADER` and `ROLE_ADMIN`, which administers the others.

#### 3.1.1. Base Strategy Interface

All strategies must implement the `IStrategyTemplate` interface, which defines the core functionality required for strategy contracts:

**Required Functions** (defined in `src/interface/IStrategyTemplate.sol`):
```js
function allocateFunds(bytes calldata data) external returns (uint256)
function deallocateFunds(bytes calldata data) external returns (uint256)
function onWithdraw(uint256 assets) external returns (uint256)
function rescueToken(address token, uint256 amount) external
function asset() external view returns (address)
function getVault() external view returns (address)
function strategyType() external view returns (StrategyType)
function totalAllocatedValue() external view returns (uint256)
function maxAllocation() external view returns (uint256)
function maxWithdraw() external view returns (uint256)
```

**Strategy Types:**
- `ATOMIC`: Strategy that executes operations atomically, provides on-chain accurate accounting of yield
- `ASYNC`: Strategy that requires asynchronous operations (multiple transactions), can provide stale accounting of yield
- `CROSSCHAIN`: Strategy that operates across different blockchain networks, can provide stale accounting of yield

**Key Requirements:**
- Must emit `AllocateFunds` event when funds are allocated
- Must emit `DeallocateFunds` event when funds are deallocated
- Must revert if operations cannot be completed (slippage, limits, etc.)
- Must implement proper access controls to ensure only authorized vaults can call functions
- Must use the same underlying asset as the vault

#### 3.1.2. Allocator Fund Movement

The Allocator role manages fund allocation and deallocation through the `AllocateModule` (`src/module/AllocateModule.sol`). The process works as follows:

**Allocation Process:**
1. The Allocator calls `vault.allocate(bytes calldata data)` with ABI-encoded `AllocateParams[]`
2. The vault delegates to the `AllocateModule.allocateFunds()` function
3. For each allocation parameter:
   - If `isDeposit` is true: calls `strategy.allocateFunds(extraData)`
   - If `isDeposit` is false: calls `strategy.deallocateFunds(extraData)`
4. Updates the vault's internal accounting of allocated amounts
5. Emits `AllocatedFunds` event for each operation

**AllocateParams Structure** (defined in `src/interface/IAllocateModule.sol`):
```js
struct AllocateParams {
    bool isDeposit;         // true for allocation, false for deallocation
    address strategy;        // Strategy contract address
    bytes extraData;        // Strategy-specific parameters
}

event AllocatedFunds(address indexed strategy, bool indexed isDeposit, uint256 amount, bytes extraData);
```

**Access Control:**
- Only accounts with the `ALLOCATOR` role can call allocation functions
- Only active strategies can receive new allocations
- The vault automatically handles token approvals and accounting updates

#### 3.1.3. Multisig Strategies

The `MultisigStrategy` (`src/periphery/strategies/MultisigStrategy.sol`) is a specialized strategy implementation that forwards assets to a designated multi-signature wallet. This strategy is useful for:

**Key Features:**
- **Asset Forwarding**: Simply forwards deposits to a multi-sig wallet
- **Asset Retrieval**: Retrieves assets from the multi-sig on withdrawal
- **No Yield Generation**: Does not generate any rewards, purely for custody
- **Position Accounting**: Implements position accounting with configurable thresholds. The operator reports the position via `adjustTotalAssets(diff, nonce)`. A change outside the threshold or inside the cooldown pauses the strategy, and a report older than the validity period blocks further operations.

**Initialization Parameters:**
```js
function initialize(
    address admin,                           // Strategy admin
    address vault_,                         // Authorized vault
    address multiSig_,                      // Multi-sig wallet address
    uint64 maxAccountingChangeThreshold_,   // Max accounting change (basis points)
    uint64 accountingValidityPeriod_,       // Accounting validity period (seconds)
    uint64 cooldownPeriod_,                 // Update cooldown period (seconds)
    address timelock_                       // Timelock (address(0) for none)
)
```

**Access Control:**
- `STRATEGY_ADMIN`: Can change the multi-sig address and update accounting parameters. Changing the multi-sig is timelocked and two-step: `setMultiSig` proposes, the new multi-sig confirms with `acceptMultiSig`.
- `OPERATOR_ROLE`: Can execute allocation and deallocation operations
- Only the authorized vault can call strategy functions

**Events:**
- `MultiSigTransferStarted`: Emitted when a new multi-sig address is proposed
- `MultiSigSet`: Emitted when the multi-sig address is updated
- `AssetsForwarded`: Emitted when assets are sent to the multi-sig
- `AssetsRetrieved`: Emitted when assets are retrieved from the multi-sig
- `AdjustTotalAssets`: Emitted when total assets are adjusted

#### 3.1.4. Simple and Multi-Asset Strategies

- **`SimpleStrategy`**: holds the assets without generating yield. Used for testing or as a fallback strategy.
- **`MultiAssetStrategy`**: a `MultisigStrategy` that also implements `allocateFundsMultiAsset` (`IMultiAssetDepositStrategy`). It receives the non-base deposits of a multi-asset deposit vault (see [Section 2.6.5](#265-multi-asset-deposit-vault)), forwards the raw token to the multisig and books the base value that the vault supplies.

#### 3.1.5. Looping Strategies

Looping strategies increase exposure to an asset by borrowing against it at a lending market and keep the loan-to-value ratio within a configured band. `BaseLoopingStrategy` combines `BaseStrategy` with the `LoopingPrimitive`, which leverages and deleverages with flash loans. The lending market, flash loans and swaps are plugged in as modules (`LenderModuleAaveV3`, `FlashModuleAaveV3`, `SwapModuleUniV3`, `SwapModuleUniV4AndVaultDeposit` in `src/periphery/auxiliary/`). `ConcreteStandardLoopingStrategy` is the deployable implementation.

See [ConcreteLoopingStrategy](./spec/ConcreteLoopingStrategy.md).

### 3.2. Hooks

Hooks provide a mechanism for custom logic to be executed at specific points during vault operations. The hook system uses a struct containing an address and flags to determine which hooks are active. Hook interface and library are located in `src/interface/IHook.sol` and `src/lib/Hooks.sol`.

**Hooks Structure:**
```js
struct Hooks {
    address target;  // Address of the hook contract
    uint96 flags;    // Bit flags indicating which hooks are active
}
```

**Available Hook Types:**
- `PRE_DEPOSIT` (1): Called before deposit operations
- `POST_DEPOSIT` (2): Called after deposit operations
- `PRE_MINT` (3): Called before mint operations
- `POST_MINT` (4): Called after mint operations
- `PRE_WITHDRAW` (5): Called before withdraw operations
- `POST_WITHDRAW` (6): Called after withdraw operations
- `PRE_REDEEM` (7): Called before redeem operations
- `POST_REDEEM` (8): Called after redeem operations
- `PRE_ADD_STRATEGY` (9): Called before adding strategies
- `PRE_REMOVE_STRATEGY` (10): Called before removing strategies
- `PRE_TRANSFER` (11): Called before share transfers
- `POST_TRANSFER` (12): Called after share transfers
- `PRE_MULTI_DEPOSIT` (13): Called before non-base deposits on a multi-asset deposit vault

**Hook Interface:**
Hook contracts must implement the `IHook` interface (`src/interface/IHook.sol`) with functions for each hook type:
```js
function preDeposit(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets) external;
function postDeposit(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets) external;
function preTransfer(address sender, address from, address to, uint256 shares) external;
// ... other hook functions
```

**Access Control:**
- Only accounts with the `HOOK_MANAGER` role can set hooks via `vault.setHooks(Hooks memory hooks)` (timelocked)

**Hook Contracts** (`src/periphery/hooks/`):

All hooks inherit from `BaseHook` (owner-managed ones from `BaseOwnableHook`). Each hook is deployed as a clone for exactly one vault through the `PeripheryFactory` (see [Section 3.7](#37-periphery-factory)).

| Hook | Purpose |
|----------|-------|
| `HookContainer` | Combines several sub-hooks on one vault and calls them in sequence |
| `UserDepositCapHook` | Per-user deposit cap |
| `WhitelistUserDepositHook` | Whitelist plus per-user deposit cap |
| `DepositLockHook` | Time-locks newly minted shares against transfer, withdraw and redeem |
| `DepositLockWithFeeHook` | Deposit lock with an early unlock for a fee |
| `DepositLockRegSHook` | Three-stage lock for Reg S share classes |
| `MultiAssetDepositCapHook` | Lifetime deposit cap per non-base token, on `PRE_MULTI_DEPOSIT` |

See [DepositLockHooks](./spec/DepositLockHooks.md) and [DepositLockRegSHook](./spec/DepositLockRegSHook.md).

**Which hooks see multi-asset deposits:**

A hook on `PRE_DEPOSIT` / `POST_DEPOSIT` sees **both** base and non-base deposits; only `PRE_MULTI_DEPOSIT` is exclusive to non-base ones. So `UserDepositCapHook`'s per-user cap is consumed by a non-base deposit at its base-equivalent value, and `WhitelistUserDepositHook` / `DepositLockHook` apply to non-base deposits too. This is deliberate: those hooks gate and track *share issuance*, and both paths mint the same shares. `MultiAssetDepositCapHook` is complementary, capping each raw deposit token in its own decimals.

The `assets` argument on `PRE_DEPOSIT` / `POST_DEPOSIT` is a base-asset-equivalent *notional*. On a non-base deposit no `asset()` enters the vault, so a custom hook must not reconcile that value against `asset().balanceOf(vault)`.

### 3.3. Fee Splitter

The `TwoWayFeeSplitter` (`src/periphery/auxiliary/TwoWayFeeSplitter.sol`) is the primary fee distribution mechanism in Concrete V2. It allows fees to be split between two recipients with configurable ratios.

**Key Features:**
- **Two Recipients**: Main recipient (curator) and secondary recipient (service provider)
- **Configurable Split**: Fee fraction determines the distribution ratio
- **Automatic Distribution**: Fees are automatically distributed when `distributeFees()` is called
- **Multi-Vault Support**: Can handle fees from multiple vaults simultaneously

**Recipients:**
- **Main Recipient**: Typically the vault curator who manages the vault
- **Secondary Recipient**: Typically Concrete (the service provider)

**Fee Distribution Logic:**
```js
// If feeFractionOfSecondaryRecipient = 0: All fees go to main recipient
// If feeFractionOfSecondaryRecipient = 10000 (100%): All fees go to secondary recipient
// Otherwise: Fees are split proportionally
```

**Access Control:**
- **Fee Splitter Owner**: Can set the full split, the secondary recipient and fee fractions, and rescue tokens
- **Fee Splitter Owner or Vault Manager**: Can set the main recipient for their vault
- **Anyone**: Can call `distributeFees()` to trigger distribution

**Key Functions:**
```js
function distributeFees(address vault) external                    // Distribute accumulated fees
function setFeeSplit(address vault, uint32 feeFractionOfSecondaryRecipient, address mainRecipient, address secondaryRecipient) external
function setMainRecipient(address vault, address newMainRecipient) external
function setSecondaryRecipient(address vault, address secondaryRecipient) external
function setFeeFraction(address vault, uint32 newFeeFractionOfSecondaryRecipient) external
```

**Events:**
- `FeesDistributed`: Emitted when fees are distributed to recipients
- `MainRecipientSet`: Emitted when main recipient is updated
- `SecondaryRecipientSet`: Emitted when secondary recipient is updated
- `FeeFractionSet`: Emitted when fee fraction is updated

### 3.4. Fee Accountant

The `FeeAccountant` (`src/periphery/auxiliary/FeeAccountant.sol`) is an alternative fee recipient for a single vault. It holds the fee shares and lets authorized distributors send them to whitelisted recipients in one call (`distributeFeeShares`). The events include the share price at the time of distribution. It is deployed behind a UUPS proxy.

### 3.5. Asset Pricers and Oracle Module

A multi-asset deposit vault values non-base deposits through an asset pricer (`IAssetPricer`, `src/pricer/`):
- **`OneToOneAssetPricer`**: one unit of the deposit token equals one unit of the base asset, adjusted for decimals. For assets with the same peg.
- **`OracleAssetPricer`**: `price(depositToken) / price(baseAsset)` from an `OracleModule`, rounded down.

The **`OracleModule`** (`src/periphery/oracle/`) is a registry of Chainlink feeds with per-asset price bounds and staleness checks, and an optional L2 sequencer uptime check with a grace period. Setting a feed or the sequencer oracle is timelocked, removing a feed is instant. Ownership is two-step.

### 3.6. Position Helpers

A position helper (`src/periphery/positionhelper/`) manages a leveraged lend/borrow position for a `positionOwner`, such as a multisig or strategy, and deploys the borrowed tokens into a yield vault while keeping the LTV within a band. The position owner keeps custody of collateral, debt and vault shares. Each helper is a clone with immutable arguments, deployed through the `PeripheryFactory`. Implementations: `PositionHelperAaveV3`, `PositionHelperMorpho`, `PositionHelperDolomiteNative` and `PositionHelperDolomiteAssetCX`, all on `PositionHelperBase`.

See [Position Management Helper](./spec/PositionManagementHelper.md).

### 3.7. Periphery Factory

The `PeripheryFactory` (`src/periphery/factory/`) is a UUPS-upgradeable registry and deployment factory for three kinds of periphery contracts:
- **Strategies**: deployed as `TransparentUpgradeableProxy` via `deployStrategy(uint64 implId, bytes initData)` and upgraded via `upgradeStrategy` / `batchUpgradeStrategies` along whitelisted migration paths (`setStrategyMigratable`). The factory owns each strategy's proxy admin. Existing proxies can be brought in via `registerStrategy` and handed out again via `deregisterStrategy`.
- **Position helper clones**: via `clonePMH(...)`.
- **Hook clones**: via `cloneHook(uint64 implId, address vault, bytes initData)`. Each clone is bound to one vault.

As in the vault factory, implementations are registered by their `ID()`. The factory manager approves (timelocked) and blocks implementations of each kind, and the owner unblocks them (timelocked). The factory manager can pause deployments and upgrades, and only the owner can unpause (timelocked).

See [PeripheryFactory](./spec/PeripheryFactory.md).

### 3.8. Timelock

The `Timelock` (`src/periphery/timelock/`) is a single upgradeable contract shared by all protected contracts: vaults, the factories, strategies and the oracle module. A protected contract stores the timelock address and marks functions with `afterDelay`. Such a call only succeeds once the same call has been proposed on the timelock and its delay has passed. The original role or owner check remains in place.

Each protected function is assigned a tier:

| Tier | Default delay | Typical use |
|----------|-------|-------|
| `TIER_1` | 48 h | upgrades, ownership transfer |
| `TIER_2` | 24 h | most operational changes |
| `TIER_3` | 12 h | low-impact changes |

**Timelock roles:** `PROPOSER` (proposes calls), `GUARDIAN` (cancels queued calls), `CONFIG` (tiers and contract bindings), `OVERRIDE` (skips the remaining delay of a queued call), `UPGRADER` and `JANITOR` (removes stale entries).

`activateTimelock()` on a protected contract is a one-way switch. Before it, `afterDelay` has no effect, which allows initial configuration without delays.

See [Timelock](./spec/Timelock.md).
