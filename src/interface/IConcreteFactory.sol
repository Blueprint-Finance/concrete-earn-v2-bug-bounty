// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

interface IConcreteFactory {
    error AlreadyBlocked();
    error AlreadyApproved();
    error InvalidImplementation();
    error InvalidVersion();
    error NotOwner();
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
     * @notice Emitted when the default configuration is updated.
     * @param managementFeeRecipient new default management fee recipient
     * @param performanceFeeRecipient new default performance fee recipient
     */
    event DefaultEnforcedVaultConfigurationUpdated(
        address indexed managementFeeRecipient, address indexed performanceFeeRecipient
    );

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
     * @dev Only the vault owner can initiate upgrade. The new vault ID must be higher than the current vault ID.
     */
    function upgrade(address vault, uint64 newVaultImpl, bytes calldata data) external;

    /**
     * @notice Upgrade multiple vaults to a new implementation vault ID in a single transaction.
     * @param vaultAddresses array of vault addresses to upgrade
     * @param newVaultImpl new vault ID to upgrade all vaults to
     * @param data upgrade data to use for all vault upgrades
     * @dev Only the vault owners can initiate upgrade for their respective vaults. The new vault ID must be higher than the current vault ID for each vault.
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
     * @dev Only the factory owner can register vaults. The vault must be a valid upgradeable vault.
     */
    function registerVault(address vault) external;

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
