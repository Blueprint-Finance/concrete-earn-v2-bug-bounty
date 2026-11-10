// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IDefaultEnforcedVaultConfiguration} from "./IDefaultEnforcedVaultConfiguration.sol";

interface IUpgradeableVault {
    error AlreadyInitialized();
    error NotFactory();
    error NotInitialized();
    error InvalidFactoryOwner();
    error InvalidVaultImpl();

    /**
     * @notice Get the factory's address.
     * @return address of the factory
     */
    function factory() external view returns (address);

    /**
     * @notice Get the vault's Initialization version.
     * @return version of the vault (not necessarily the same as the Id of the vault)
     * @dev Starts from 1 and is incremented by 1 for each upgrade (except for legacy versions, which were upgraded also in larger increments)
     */
    function version() external view returns (uint64);

    /**
     * @notice Initialize `UpgradeableVaultProxy` contract by using a given data and setting a particular version and owner.
     * @param initialVersion initial version of the vault
     * @param owner initial owner of the vault
     * @param defaultEnforcedVaultConfig default configuration from the factory
     * @param data some data to use
     */
    function initialize(
        uint64 initialVersion,
        address owner,
        IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration calldata defaultEnforcedVaultConfig,
        bytes calldata data
    ) external;

    /**
     * @notice Upgrade this vault to a specific newer version using a given data.
     * @param newVaultImpl new vault ID to upgrade to
     * @param data some data to use
     */
    function upgrade(uint64 newVaultImpl, bytes calldata data) external;
}
