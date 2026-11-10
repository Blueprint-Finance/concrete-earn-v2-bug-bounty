// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {ITimelockProtected} from "./ITimelockProtected.sol";

interface IConcreteFactory is ITimelockProtected {
    error AlreadyBlocked();
    /// @notice Thrown when unblocking an implementation that is not currently blocked.
    error NotBlocked();
    /// @notice Thrown when unsetting a migration path that is not currently open.
    error NotMigratable();
    error AlreadyApproved();
    error InvalidImplementation();
    error InvalidVersion();
    error NotOwner();
    /// @notice Thrown when a FACTORY_MANAGER-gated function is called by a non-manager.
    error NotFactoryManager();
    error NotRegisteredVault();
    error OldVersion();
    error ImplementationBlocked();
    error CanNotMigrate();
    error InvalidFactoryOwner();
    error VaultAlreadyRegistered();
    error ZeroAddress();
    error InvalidVaultAddress();
    error InvalidDataLength();
    error ProxyBytecodeNotInitialized();
    error ImplementationNotFound();
    error ZeroVaultImplId();

    /// @notice Thrown when renounceOwnership is called — permanently disabled.
    error RenounceOwnershipDisabled();

    /**
     * @notice Emitted when a new vault is deployed.
     * @param vault address of the new vault
     * @param vaultImpl vault ID of the new vault
     * @param owner address of the owner of the new vault
     */
    event Deployed(address indexed vault, uint64 indexed vaultImpl, address indexed owner);

    /**
     * @notice Emitted when a new implementation is approved.
     * @param implementation address of the new implementation
     */
    event ApprovedImplementation(address indexed implementation);

    /**
     * @notice Emitted when a new vault ID is approved.
     * @param vaultImpl ID of the new vault
     * @param implementation address of the new implementation
     */
    event NewVaultImplToImplementation(uint64 indexed vaultImpl, address indexed implementation);

    /**
     * @notice Emitted when an implementation is blocked.
     * @param vaultImpl vault ID of the implementation that was blocked
     */
    event Blocked(uint64 indexed vaultImpl);

    /**
     * @notice Emitted when a previously-blocked implementation is unblocked.
     * @param vaultImpl vault ID of the implementation that was unblocked
     */
    event Unblocked(uint64 indexed vaultImpl);

    /**
     * @notice Emitted when a migration path is closed.
     * @param fromVaultImpl source vault ID whose migration path was closed
     * @param toVaultImpl target vault ID whose migration path was closed
     */
    event MigratableUnset(uint64 indexed fromVaultImpl, uint64 indexed toVaultImpl);

    /**
     * @notice Emitted when a vault ID is set as migratable to another vault ID.
     * @param fromVaultImpl vault ID that was set as migratable
     * @param toVaultImpl vault ID that was set as migratable
     */
    event Migratable(uint64 indexed fromVaultImpl, uint64 indexed toVaultImpl);

    /**
     * @notice Emitted when an vault is migrated to a new vault ID.
     * @param vault address of the vault
     * @param newVaultImpl new vault ID of the vault
     */
    event Migrated(address indexed vault, uint64 newVaultImpl);

    /**
     * @notice Emitted when a vault is registered with the factory.
     * @param vault address of the vault that was registered
     */
    event VaultRegistered(address indexed vault);

    /**
     * @notice Emitted when the factory manager is set.
     * @param previousManager the previous factory manager address
     * @param newManager the new factory manager address
     */
    event FactoryManagerSet(address indexed previousManager, address indexed newManager);

    /**
     * @notice Emitted when the default configuration is updated.
     * @param managementFeeRecipient new default management fee recipient
     * @param performanceFeeRecipient new default performance fee recipient
     */
    event DefaultEnforcedVaultConfigurationUpdated(
        address indexed managementFeeRecipient, address indexed performanceFeeRecipient
    );

    /**
     * @notice Emitted when an upgrade of the factory itself is authorized.
     * @param newImplementation address of the implementation the factory is upgrading to
     * @param authorizedBy address that authorized the upgrade (the factory owner)
     * @dev Emitted in addition to OpenZeppelin's {IERC1967.Upgraded} so that monitoring can
     *      attribute the upgrade to the queued timelock proposal that authorized it.
     */
    event FactoryUpgradeAuthorized(address indexed newImplementation, address indexed authorizedBy);

    /**
     * @notice Approve a new implementation for using to deploy a proxy.
     * @param implementation address of the new implementation
     */
    function approveImplementation(address implementation) external;

    /**
     * @notice Block an implementation.
     * @param vaultImpl vault ID of the implementation to block
     */
    function blockImplementation(uint64 vaultImpl) external;

    /**
     * @notice Unblock a previously-blocked implementation.
     * @param vaultImpl vault ID of the implementation to unblock
     * @dev Owner-only and timelock-gated (Tier 2). Reverts if not currently blocked.
     */
    function unblockImplementation(uint64 vaultImpl) external;

    /**
     * @notice Block an implementation by its address.
     * @param implementation address of the implementation to block
     * @dev This is a convenience function that finds the version internally.
     *      Reverts if the implementation is not found.
     */
    function blockImplementationByAddress(address implementation) external;

    /**
     * @notice Set a vault ID as migratable to another vault ID.
     * @param fromVaultImpl vault ID to set as migratable
     * @param toVaultImpl vault ID to set as migratable
     */
    function setMigratable(uint64 fromVaultImpl, uint64 toVaultImpl) external;

    /**
     * @notice Close a previously-opened migration path between vault IDs.
     * @param fromVaultImpl source vault ID of the migration path to close
     * @param toVaultImpl target vault ID of the migration path to close
     * @dev Factory-manager-only and NOT timelocked. Reverts if the path is not currently open.
     */
    function unsetMigratable(uint64 fromVaultImpl, uint64 toVaultImpl) external;

    /**
     * @notice Set migration path by implementation addresses.
     * @param fromImplementation address of the source implementation
     * @param toImplementation address of the target implementation
     * @dev This is a convenience function that finds the versions internally.
     *      Reverts if either implementation is not found.
     */
    function setMigratableByAddress(address fromImplementation, address toImplementation) external;

    /**
     * @notice Deploy a new proxy vault.
     * @param vaultImpl vault's ID to use
     * @param owner initial owner of the vault
     * @param data initial data for the vault creation
     * @return address of the vault
     * @dev CREATE2 salt is constructed from the given parameters.
     */
    function create(uint64 vaultImpl, address owner, bytes calldata data) external returns (address);

    /**
     * @notice Deploy a new proxy vault.
     * @param vaultImpl vault's ID to use
     * @param owner initial owner of the vault
     * @param data initial data for the vault creation
     * @return address of the vault
     * @dev CREATE2 salt is constructed from the given parameters.
     */
    function create(uint64 vaultImpl, address owner, bytes calldata data, bytes32 salt) external returns (address);

    /**
     * @notice Predict the address of a vault that would be deployed with the given parameters.
     * @param vaultImpl vault's ID to use
     * @param ownerAddr initial owner of the vault
     * @param data initial data for the vault creation
     * @return predicted address of the vault
     */
    function predictVaultAddress(uint64 vaultImpl, address ownerAddr, bytes calldata data)
        external
        view
        returns (address);

    /**
     * @notice Predict the address of a vault that would be deployed with the given parameters.
     * @param vaultImpl vault's ID to use
     * @param ownerAddr initial owner of the vault
     * @param data initial data for the vault creation
     * @param salt for CREATE2 deployment.
     * @return predicted address of the vault
     */
    function predictVaultAddress(uint64 vaultImpl, address ownerAddr, bytes calldata data, bytes32 salt)
        external
        view
        returns (address);

    /**
     * @notice Upgrade a vault to a new implementation vault ID.
     * @param vault address of the vault to upgrade
     * @param newVaultImpl new vault ID to upgrade to
     * @param data upgrade data
     * @dev Only the vault owner can initiate upgrade, and only while the factory is not paused. The new vault ID
     *      must be approved, not blocked and migratable from the vault's current ID (see `setMigratable`).
     *      For legacy sequential versions it must also be higher than the current version.
     */
    function upgrade(address vault, uint64 newVaultImpl, bytes calldata data) external;

    /**
     * @notice Upgrade multiple vaults to a new implementation vault ID in a single transaction.
     * @param vaultAddresses array of vault addresses to upgrade
     * @param newVaultImpl new vault ID to upgrade all vaults to
     * @param data upgrade data to use for all vault upgrades
     * @dev Only the vault owners can initiate upgrade for their respective vaults, and only while the factory is not
     *      paused. The same conditions as for `upgrade` apply to each vault.
     */
    function batchUpgrade(address[] calldata vaultAddresses, uint64 newVaultImpl, bytes[] calldata data) external;

    /**
     * @notice Get the last available version.
     * @return version of the last implementation
     * @dev If zero, no implementations are approved.
     */
    function lastVersion() external view returns (uint64);

    /**
     * @notice Get the implementation for a given vault ID.
     * @param vaultImpl vault ID to get the implementation for
     * @return address of the implementation
     * @dev First checks if vaultImplToImplementation mapping has an entry, otherwise falls back to getImplementationByVersion.
     */
    function getImplementationByVaultImpl(uint64 vaultImpl) external view returns (address);

    /**
     * @notice Get if an implementation is blocked
     * @param vaultImpl vault ID to check
     * @return bool true if the implementation is blocked
     */
    function isBlocked(uint64 vaultImpl) external view returns (bool);

    /**
     * @notice Get if a vault ID is migratable to another vault ID
     * @param fromVaultImpl vault ID to check
     * @param toVaultImpl vault ID to check
     * @return bool true if the vault ID is migratable
     */
    function isMigratable(uint64 fromVaultImpl, uint64 toVaultImpl) external view returns (bool);

    /**
     * @notice Check if a vault was deployed by this factory
     * @param vault The vault address to check
     * @return True if the vault was deployed by this factory, false otherwise
     */
    function isRegisteredVault(address vault) external view returns (bool);

    /**
     * @notice Register a previously deployed vault with this factory for management
     * @param vault The vault address to register
     * @dev Only the factory manager can register vaults. The vault must be a valid upgradeable vault.
     */
    function registerVault(address vault) external;

    /**
     * @notice Assign the FACTORY_MANAGER role to an address.
     * @param manager The address to grant the factory manager role
     * @dev Only the factory owner can set this. The manager handles frequent operational
     *      functions while the owner retains the high-privilege (VVIP) functions.
     */
    function setFactoryManager(address manager) external;

    /**
     * @notice Get the current factory manager address.
     * @return The address holding the FACTORY_MANAGER role
     */
    function getFactoryManager() external view returns (address);

    /**
     * @notice Pause the factory, blocking new vault deployments via {create}.
     * @dev Only the factory manager can pause. Immediate (no timelock) so deployments
     *      can be halted promptly in an emergency.
     */
    function pause() external;

    /**
     * @notice Unpause the factory, re-enabling new vault deployments via {create}.
     * @dev Only the owner can unpause and only behind the timelock.
     */
    function unpause() external;

    /**
     * @notice Set the default fee configuration for new vaults.
     * @param managementFeeRecipient The address of the default management fee recipient
     * @param performanceFeeRecipient The address of the default performance fee recipient
     * @dev Only the factory owner can set this. Applied to newly created vaults.
     */
    function setDefaultEnforcedVaultConfiguration(address managementFeeRecipient, address performanceFeeRecipient)
        external;

    /**
     * @notice Get the default configuration for new vaults.
     * @return defaultManagementFeeRecipient The default management fee recipient
     * @return defaultPerformanceFeeRecipient The default performance fee recipient
     */
    function getDefaultEnforcedVaultConfiguration()
        external
        view
        returns (address defaultManagementFeeRecipient, address defaultPerformanceFeeRecipient);
}
