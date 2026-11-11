<p align="center">
  <img src="doc/img/concrete-logo.png" alt="Concrete logo" width="200" />
</p>

# Earn V2 

## 1. Overview

Concrete Earn V2 is a protocol for permissionless vault deployment with multi-strategy yield aggregation. The protocol enables curators to deploy ERC4626-compliant vaults that allocate funds across multiple yield-generating strategies with built-in fee management, upgradability, and advanced withdrawal systems.

**Key Features:**
- 🏭 **Factory-based deployment**: Permissionless vault creation with version management
- 🏦 **Multi-strategy vaults**: Allocate funds across multiple strategies for optimized yields
- 💰 **Fee management**: Built-in management and performance fees with configurable recipients
- ⚡ **Async withdrawals**: Queue-based withdrawal system for better liquidity management
- 🔄 **Upgradeable**: UUPS proxy pattern for vault and factory upgrades
- 🎣 **Hooks system**: Custom validation logic at key vault operation points

---

## 2. Documentation

### Core Documentation

- **[Architecture](./doc/Architecture.md)** - Comprehensive system architecture covering factory, vaults, strategies, hooks, and fee mechanisms
- **[Testing](./doc/Testing.md)** - Complete testing guide including unit tests, fuzz tests, invariant tests, E2E tests, and testing utilities

### Technical Specifications

- **[ConcreteAsyncVaultImpl](./doc/spec/ConcreteAsyncVaultImpl.md)** - Asynchronous withdrawal system with state machines, sequence diagrams, and mathematical proofs
- **[PartialEpochProcessing](./doc/spec/PartialEpochProcessing.md)** and **[PriorityWithdrawal](./doc/spec/PriorityWithdrawal.md)** - Async vault withdrawal extensions
- **[ConcretePredepositVaultImpl](./doc/spec/ConcretePredepositVaultImpl.md)** - Pre-deposit vault and L1 → L2 migration
- **[ERC-4626 compliance check](./doc/spec/ConcreteStandardVaultImpl_erc4626_compliance_check.md)** - Standard vault against ERC-4626
- **[HurdleRatePerformanceFee](./doc/spec/HurdleRatePerformanceFee.md)** - Hurdle-gated performance fee
- **[HaltedStrategyHandling](./doc/spec/HaltedStrategyHandling.md)** - Halting and reconciling strategies
- **[ConcreteLoopingStrategy](./doc/spec/ConcreteLoopingStrategy.md)** - Leveraged looping strategies
- **[DepositLockHooks](./doc/spec/DepositLockHooks.md)** and **[DepositLockRegSHook](./doc/spec/DepositLockRegSHook.md)** - Share time-lock hooks
- **[PeripheryFactory](./doc/spec/PeripheryFactory.md)** - Deployment and upgrades of strategies, position helpers and hooks
- **[Timelock](./doc/spec/Timelock.md)** - Tiered timelock for privileged calls
- **[Position Management Helper](./doc/spec/PositionManagementHelper.md)** - Leveraged position helper with LTV management

### Diagrams, Releases and Audits

- **[Architecture diagram](./doc/diagrams/sc_arch_diagram.svg)** and **[async queue diagram](./doc/diagrams/sc_async_queue_diagram.svg)**
- **[Release notes](./doc/releases/)** and **[CHANGELOG](./CHANGELOG.md)**
- **[Audit reports](./audit/)**

### Quick Links by Topic

**Understanding the System:**
- Start with [Architecture Overview](./doc/Architecture.md#overview)
- Learn about [Vault Implementations](./doc/Architecture.md#26-concrete-vault-implmentations)
- Understand [Factory Deployment](./doc/Architecture.md#11-vault-deployment)

**About Tests:**
- [Testing Guidelines](./doc/Testing.md#1-testing-guidelines) - Best practices for writing tests
- [Unit Tests](./doc/Testing.md#2-unit-testing)
- [Fuzz Tests](./doc/Testing.md#3-fuzz-testing)
- [E2E Tests](./doc/Testing.md#4-end-to-end-testing)
- [Testing Utilities Reference](./doc/Testing.md#5-testing-utilities)

**Advanced Topics:**
- [Asynchronous Vault Details](./doc/spec/ConcreteAsyncVaultImpl.md)
- [Access Control & Roles](./doc/Architecture.md#25-access-control-and-vault-operations)
- [Fee System](./doc/Architecture.md#24-fees)
- [Strategies](./doc/Architecture.md#31-strategies)

---

## 3. Getting Started

### 3.1 Pre-requisites

#### Node.js and npm

**Required versions:**
- Node.js ≥ 20
- npm ≥ 10

**How to install:**

Option 1: Download from [nodejs.org](https://nodejs.org/)

Option 2: Using nvm (recommended):
```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash
nvm install 20
nvm use 20
```

#### Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

**Solidity version used:** 0.8.27

**How to install:**
```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

Foundry consists of:
- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools)
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network
- **Chisel**: Fast, utilitarian, and verbose solidity REPL

**Documentation:** https://book.getfoundry.sh/


### 3.2 Commands

**Install dependencies:**
```bash
npm install
```
Or if using yarn:
```bash
yarn install
```

**Build the project:**
```bash
forge build
```

**Run tests:**
```bash
# All tests
forge test

# With verbosity
forge test -vvv

# Specific test types
forge test --match-path 'test/unit-test/**'  # Core unit tests
forge test --match-path 'test/periphery/**'  # Periphery tests
forge test --match-path 'test/fuzz/**'       # Fuzz tests
forge test --match-path 'test/E2E/**'        # E2E tests
FOUNDRY_PROFILE=invariant forge test -vv     # Invariant tests
```

**Check coverage:**
```bash 
FOUNDRY_PROFILE=coverage forge coverage --ir-minimum
```

---

## 4. Repository Structure

```
src/
├── common/              # Shared base contracts (UpgradeableVault, transfer-hook ERC20, contract IDs)
├── factory/             # ConcreteFactory and VaultProxy
├── implementation/      # Vault implementations (Standard, Async, Bridged, Predeposit, Multi-Asset Deposit)
├── interface/           # Core interfaces
├── lib/                 # Vault libraries (accounting, withdrawals, hooks, roles) and storage/
├── module/              # AllocateModule
├── oracle/              # Hurdle rate oracles (APR, APY, off-chain)
├── pricer/              # Asset pricers for multi-asset deposits
└── periphery/
    ├── auxiliary/       # Fee splitter, fee accountant, flash/lender/swap modules
    ├── factory/         # PeripheryFactory
    ├── hooks/           # Vault hooks (container, deposit caps, whitelist, deposit locks)
    ├── interface/       # Periphery interfaces
    ├── lenders/         # Lender adapters
    ├── lib/             # Periphery libraries and storage
    ├── oracle/          # OracleModule (Chainlink feeds)
    ├── positionhelper/  # Position helpers (Aave V3, Morpho, Dolomite)
    ├── predeposit/      # Pre-deposit OApp and ShareDistributor
    ├── strategies/      # Strategies (Simple, Multisig, Multi-Asset, Looping)
    ├── timelock/        # Timelock
    └── traits/          # Shared asset/lender helpers

test/
├── common/              # Base test setups and utilities
├── mock/, mocks/        # Mock contracts
├── unit-test/           # Core unit tests
├── periphery/           # Periphery unit, fuzz and E2E tests
├── fuzz/                # Fuzz tests
├── invariant/           # Invariant tests with handlers
├── E2E/                 # End-to-end scenario tests
└── property/            # ERC-4626 property tests

doc/
├── Architecture.md      # System architecture
├── Testing.md           # Testing guide and reference
├── spec/                # Technical specifications
├── diagrams/            # Architecture and async queue diagrams
└── releases/            # Release notes

audit/                   # Audit reports
```

---

## 5. Key Contracts

### Core Contracts

| Contract | Location | Description |
|----------|----------|-------------|
| `ConcreteFactory` | `src/factory/` | Factory for deploying and upgrading vaults |
| `VaultProxy` | `src/factory/` | ERC1967 proxy for vault implementations |
| `UpgradeableVault` | `src/common/` | Base contract handling vault upgrades |
| `ConcreteStandardVaultImpl` | `src/implementation/` | Standard multi-strategy ERC4626 vault |
| `ConcreteAsyncVaultImpl` | `src/implementation/` | Async vault with queue-based withdrawals |
| `ConcretePredepositVaultImpl` | `src/implementation/` | Pre-deposit vault with L1 → L2 migration |
| `ConcreteBridgedAsyncVaultImpl` | `src/implementation/` | L2 async vault receiving bridged shares |
| `ConcreteBridgedStandardVaultImpl` | `src/implementation/` | Standard vault used as a migration target |
| `ConcreteMultiAssetDepositAsyncVault` | `src/implementation/` | Async vault accepting deposits in several assets |
| `AllocateModule` | `src/module/` | Handles fund allocation to strategies |
| `Hooks` | `src/lib/` | Hook system for custom vault logic |

### Peripheral Contracts

| Contract | Location | Description |
|----------|----------|-------------|
| `PeripheryFactory` | `src/periphery/factory/` | Deploys and upgrades strategies; deploys position helper and hook clones |
| `Timelock` | `src/periphery/timelock/` | Tiered delays on privileged calls |
| `BaseStrategy` | `src/periphery/strategies/` | Base strategy implementation |
| `SimpleStrategy` | `src/periphery/strategies/` | Simple strategy with direct fund management |
| `MultisigStrategy` | `src/periphery/strategies/` | Strategy forwarding funds to multisig |
| `MultiAssetStrategy` | `src/periphery/strategies/` | Multisig strategy that also takes non-base deposits |
| `ConcreteStandardLoopingStrategy` | `src/periphery/strategies/` | Leveraged looping strategy |
| `HookContainer` | `src/periphery/hooks/` | Combines several hooks on one vault |
| `PositionHelperBase` | `src/periphery/positionhelper/` | Leveraged position helper with LTV management |
| `OracleAssetPricer` / `OneToOneAssetPricer` | `src/pricer/` | Value deposit assets in base-asset units |
| `TwoWayFeeSplitter` | `src/periphery/auxiliary/` | Fee distribution between two recipients |

---

## 6. Deployments

### Ethereum Mainnet (Chain ID: 1)

Contracts provided by Concrete: the factories, the timelock, the allocate module and the implementations from release 1.5.0 onwards. Vaults and the strategy and hook instances that belong to them are not listed, since they are deployed per vault through the factories. Whether an implementation can still be used for new deployments or upgrades is recorded on-chain in the factories (e.g. `ConcreteFactory.isBlocked`).

#### Factories and Timelock

| Contract | Version | Address |
|----------|---------|---------|
| ConcreteFactory (proxy) | — | [`0x0265d73a8E61F698d8EB0dfeb91Ddce55516844C`](https://etherscan.io/address/0x0265d73a8E61F698d8EB0dfeb91Ddce55516844C) |
| PeripheryFactory (proxy) | — | [`0x0Ab99bC0f3E2a29Eb3814B872e0653734eb3E88d`](https://etherscan.io/address/0x0Ab99bC0f3E2a29Eb3814B872e0653734eb3E88d) |
| Timelock (proxy) | — | [`0x4d575bF3d22c9cd34e4ac19084397d905741d195`](https://etherscan.io/address/0x4d575bF3d22c9cd34e4ac19084397d905741d195) |
| Timelock implementation | — | [`0x775d9c510d8B7A4B76B7cd4325Deafa7a1CDc2b5`](https://etherscan.io/address/0x775d9c510d8B7A4B76B7cd4325Deafa7a1CDc2b5) |
| AllocateModule | — | [`0x14A905158aebcb44451857603006a7dc23B0D014`](https://etherscan.io/address/0x14A905158aebcb44451857603006a7dc23B0D014) |
| ConcreteFactory implementation | 1.5.0 | [`0x5442F3C0074E74DEc8a10eCc29f1BE6eA9813253`](https://etherscan.io/address/0x5442F3C0074E74DEc8a10eCc29f1BE6eA9813253) |
| PeripheryFactory implementation | 1.5.0 | [`0xb7602Daa32ed02a443d654d6E42b7001Bb42964c`](https://etherscan.io/address/0xb7602Daa32ed02a443d654d6E42b7001Bb42964c) |

#### Vault implementations

| Contract | Version | Address |
|----------|---------|---------|
| ConcreteStandardVaultImpl | 1.5.0 | [`0xF886f89b37840ca4aDf7805BBE09730dBd16Bb1C`](https://etherscan.io/address/0xF886f89b37840ca4aDf7805BBE09730dBd16Bb1C) |
| ConcreteAsyncVaultImpl | 1.5.0 | [`0x7a9B29d90286387F6bB73472468D7FF53EBaD9b8`](https://etherscan.io/address/0x7a9B29d90286387F6bB73472468D7FF53EBaD9b8) |
| ConcreteMultiAssetDepositAsyncVault | 1.7.0 | [`0xB74C14E8E5d9F5EB8C439c31a7699337B7b0556F`](https://etherscan.io/address/0xB74C14E8E5d9F5EB8C439c31a7699337B7b0556F) |

#### Strategy implementations

| Contract | Version | Address |
|----------|---------|---------|
| MultisigStrategy | 1.5.0 | [`0x41A92EA6BB4Bc0eC38a23c31F9c2f1B6BF801748`](https://etherscan.io/address/0x41A92EA6BB4Bc0eC38a23c31F9c2f1B6BF801748) |
| MultiAssetStrategy | 1.7.0 | [`0xC132f52906e6604D26C800e6d9C58b0190A2C0dE`](https://etherscan.io/address/0xC132f52906e6604D26C800e6d9C58b0190A2C0dE) |

#### Hook implementations

| Contract | Version | Address |
|----------|---------|---------|
| WhitelistUserDepositHook | 1.5.0 | [`0xE22e89083813AA3435E1cB0ce3c5830BB9C91E94`](https://etherscan.io/address/0xE22e89083813AA3435E1cB0ce3c5830BB9C91E94) |
| WhitelistUserDepositHook | 1.7.0 | [`0xecBE0ccAdE088B495591B098Dce598D830728e8a`](https://etherscan.io/address/0xecBE0ccAdE088B495591B098Dce598D830728e8a) |
| DepositLockWithFeeHook | 1.5.0 | [`0x4945172902bA94Bc1394782ED0c22e2FF7AE8F26`](https://etherscan.io/address/0x4945172902bA94Bc1394782ED0c22e2FF7AE8F26) |
| MultiAssetDepositCapHook | 1.7.0 | [`0xfbf6a62429dD6203Fbda48dC2f3f95c77CC03cAf`](https://etherscan.io/address/0xfbf6a62429dD6203Fbda48dC2f3f95c77CC03cAf) |

#### Other implementations

| Contract | Version | Address |
|----------|---------|---------|
| FeeAccountant | — | [`0x7623097a5AcA6b927E5C6f58E0a6D1bB6f222d58`](https://etherscan.io/address/0x7623097a5AcA6b927E5C6f58E0a6D1bB6f222d58) |

---

## 7. Contributing

Please read our [CONTRIBUTING.md](./CONTRIBUTING.md) guidelines before submitting pull requests. It covers our branch management policy, release process, and important requirements for code contributions.

---

## License

AGPL-3.0
