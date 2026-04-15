// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IConcreteBridgedStandardVaultImpl} from "../interface/IConcreteBridgedStandardVaultImpl.sol";
import {IContractId} from "../interface/IContractId.sol";
import {ConcreteV2RolesLib as RolesLib} from "../lib/Roles.sol";
import {ConcreteStandardVaultImpl} from "./ConcreteStandardVaultImpl.sol";
import {ContractIdEncoding} from "../lib/ContractIdEncoding.sol";

/**
 * @title ConcreteBridgedStandardVaultImpl
 * @notice A vault implementation that extends ConcreteStandardVaultImpl with unbacked minting capabilities.
 * @notice This vault type serves as a migration target - old vaults migrate TO this version during
 *      cross-chain migrations or simply migration from another vault. It allows for the initial minting of shares
 *      without depositing any underlying assets. Once the migration phase is complete, this vault
 *      can itself be migrated to a standard vault.
 */
contract ConcreteBridgedStandardVaultImpl is ConcreteStandardVaultImpl, IConcreteBridgedStandardVaultImpl {
    function ID() public pure virtual override(ConcreteStandardVaultImpl) returns (uint64) {
        // contractType=0 (vault), flavour=5 (standard bridged vault), version=1.2.0 (major=1, minor=2, patch=0)
        return uint64(510200); //ContractIdEncoding.encode(0, 5, 1, 02, 00);
    }

    /**
     * @dev Constructor
     * @param factory The address of the factory
     */
    constructor(address factory) ConcreteStandardVaultImpl(factory) {}

    /**
     * @notice Mints vault shares without depositing any underlying assets.
     * @dev Strictly `VAULT_MANAGER`.  No assets are transferred in – used only for vault migration.
     *      assets backing newly minted shares are expected to be allocated directly on strategy level.
     *      Shares are minted for later distribution to end users.
     * @param shares - Amount of shares to mint for the owner.
     */
    function unbackedMint(uint256 shares) external onlyRole(RolesLib.VAULT_MANAGER) {
        require(shares != 0, ZeroAmount());
        require(totalSupply() == 0, NotInitialMint());
        (uint256 maxDepositLimit,) = getDepositLimits();
        require(maxDepositLimit == 0, DepositLimitsNotZero());
        _mint(msg.sender, shares);
        emit UnbackedMint(shares);
    }
}

