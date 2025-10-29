# Blueprint Earn V2 Core - Bug Bounty

## Pre-requisites

### Node.js and npm

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

### Foundry

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

## Getting Set Up

1. **Install npm dependencies:**
```bash
npm install
```
Or if using yarn:
```bash
yarn install
```

2. **Build the project:**
```bash
forge build
```

3. **Run tests:**
```bash
forge test
```
