// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

/**
 * @title ConcreteFactory
 * @notice Factory for deploying and managing Concrete vault proxies and implementations.
 *         Supports deterministic deployments (CREATE2) and UUPS upgradeability with ownership controls.
 *
 * @author Blueprint Finance
 * @custom:protocol Concrete Earn V2
 * @custom:oz-upgrades Uses UUPS + eip7201 storage layout
 * @custom:source on request
 * @custom:audits on request
 * @custom:license AGPL-3.0
 */

// ─────────────────────────────────────────────────────────────────────────────
// External dependencies
// ─────────────────────────────────────────────────────────────────────────────
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Create2} from "@openzeppelin-contracts/utils/Create2.sol";
import {EnumerableSet} from "@openzeppelin-contracts/utils/structs/EnumerableSet.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Protocol-facing interfaces
// ─────────────────────────────────────────────────────────────────────────────
import {IConcreteFactory} from "../interface/IConcreteFactory.sol";
import {IUpgradeableVault} from "../interface/IUpgradeableVault.sol";
import {IContractId} from "../interface/IContractId.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Internal contracts
// ─────────────────────────────────────────────────────────────────────────────
import {IVaultProxy, VaultProxy} from "./VaultProxy.sol";
import {IDefaultEnforcedVaultConfiguration} from "../interface/IDefaultEnforcedVaultConfiguration.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Storage layout libraries
// ─────────────────────────────────────────────────────────────────────────────
import {ConcreteFactoryBaseStorageLib as CFBSLib} from "../lib/storage/ConcreteFactoryBaseStorageLib.sol";
import {DefaultEnforcedVaultConfigStorageLib as DEVCLib} from "../lib/storage/DefaultEnforcedVaultConfigStorageLib.sol";

contract ConcreteFactory is IConcreteFactory, UUPSUpgradeable, OwnableUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /**
     * @dev A modifier to validate vault ID
     * @param vaultImpl implementation's vault ID
     */
    modifier checkVersion(uint64 vaultImpl) {
        bool isValid;
        (isValid,) = _isValidVaultImpl(vaultImpl);
        require(isValid, InvalidVersion());
        _;
    }

    function _isValidVaultImpl(uint64 vaultImpl) internal view returns (bool isValid, bool isLegacyVersion) {
        address implementation = CFBSLib.fetch().vaultImplToImplementation[vaultImpl];
        if (implementation != address(0)) return (true, false);
        if (vaultImpl > 0 && vaultImpl <= lastVersion()) return (true, true);
        return (false, false);
    }

    /**
     * @dev Constructor for the ConcreteFactory contract.
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the ConcreteFactory contract.
     * @param owner_ The address of the owner of the factory.
     */
    function initialize(address owner_) external initializer {
        __Ownable_init_unchained(owner_);
        __UUPSUpgradeable_init_unchained();
    }

    /**
     * @inheritdoc IConcreteFactory
     */
    function approveImplementation(address implementation) external onlyOwner {
        require(IUpgradeableVault(implementation).factory() == address(this), InvalidImplementation());
        uint64 vaultImpl = IContractId(implementation).ID();
        require(vaultImpl != 0, ZeroVaultImplId());
        // load the storage variable
        CFBSLib.ConcreteFactoryBaseStorage storage $ = CFBSLib.fetch();
        require($.vaultImplToImplementation[vaultImpl] == address(0), AlreadyApproved());
        $.vaultImplToImplementation[vaultImpl] = implementation;
        // keeping previous event for backwards compatibility
        emit ApprovedImplementation(implementation);
        emit NewVaultImplToImplementation(vaultImpl, implementation);
    }

    /**
     * @inheritdoc IConcreteFactory
     */
    function blockImplementation(uint64 vaultImpl) external onlyOwner checkVersion(vaultImpl) {
        _blockImplementation(vaultImpl);
    }

    /**
     * @inheritdoc IConcreteFactory
     */
    function setMigratable(uint64 fromVaultImpl, uint64 toVaultImpl)
        external
        onlyOwner
        checkVersion(fromVaultImpl)
        checkVersion(toVaultImpl)
    {
        _setMigratable(fromVaultImpl, toVaultImpl);
    }

    /**
     * @inheritdoc IConcreteFactory
     */
    function blockImplementationByAddress(address implementation) external onlyOwner {
        uint64 vaultImpl = _getVaultImplByImplementation(implementation);
        _blockImplementation(vaultImpl);
    }

    /**
     * @inheritdoc IConcreteFactory
     */
    function setMigratableByAddress(address fromImplementation, address toImplementation) external onlyOwner {
        uint64 fromVaultImpl = _getVaultImplByImplementation(fromImplementation);
        uint64 toVaultImpl = _getVaultImplByImplementation(toImplementation);
        _setMigratable(fromVaultImpl, toVaultImpl);
    }

    /**
     * @dev Internal function to block an implementation by vault ID.
     * @param vaultImpl The vault ID to block
     */
    function _blockImplementation(uint64 vaultImpl) internal {
        CFBSLib.ConcreteFactoryBaseStorage storage $ = CFBSLib.fetch();
        require(!$.blocked[vaultImpl], AlreadyBlocked());

        $.blocked[vaultImpl] = true;

        emit Blocked(vaultImpl);
    }

    /**
     * @dev Internal function to set a migration path between vault IDs.
     * @param fromVaultImpl The source vault ID
     * @param toVaultImpl The target vault ID
     */
    function _setMigratable(uint64 fromVaultImpl, uint64 toVaultImpl) internal {
        // check if toVaultImpl is a legacy version
        bool isLegacyVersion;
        (, isLegacyVersion) = _isValidVaultImpl(toVaultImpl);
        bool vaultImplCondition = isLegacyVersion ? fromVaultImpl < toVaultImpl : fromVaultImpl != toVaultImpl;
        require(vaultImplCondition, OldVersion());

        CFBSLib.ConcreteFactoryBaseStorage storage $ = CFBSLib.fetch();
        $.migratable[fromVaultImpl][toVaultImpl] = true;

        emit Migratable(fromVaultImpl, toVaultImpl);
    }

    /**
     * @dev Internal function to get the vault ID by calling the ID function.
     * @param contractAddress The contract address to get the vault ID for
     * @return id The vault ID
     * @return hasNoId True if the ID function does not exist or returns not enough data to decode a uint64
     */
    function _getIdOfContract(address contractAddress) internal view returns (uint64 id, bool hasNoId) {
        (bool success, bytes memory returnData) =
            contractAddress.staticcall(abi.encodeWithSelector(IContractId.ID.selector));

        if (success && returnData.length >= 32) {
            return (abi.decode(returnData, (uint64)), false);
        }
        return (0, true);
    }

    /**
     * @dev Internal function to get the vault ID of a registered vault.
     * @param registeredVault The registered vault address to get the vault ID for
     * @return vaultImpl The vault ID
     * @dev First tries to call the ID function. If it exists, returns the vault ID. Otherwise, calls the version() function.
     *      Reverts if the registered vault is not found.
     */
    function _getVaultImplOfRegisteredVault(address registeredVault)
        internal
        view
        returns (uint64 vaultImpl, bool legacyVersion)
    {
        // first try to get the id
        (vaultImpl, legacyVersion) = _getIdOfContract(registeredVault);
        if (!legacyVersion) return (vaultImpl, false);
        // if not, fall back to legacy version-based lookup, i.e. call .version() on the registered vault
        return (IUpgradeableVault(registeredVault).version(), true);
    }

    /**
     * @dev Internal function to get the vault ID by implementation address.
     * @param implementation The implementation address to get the vault ID for
     * @return vaultImpl The legacy vault ids were incremental starting with 1. The new vault ids are queried from the implementation's ID function.
     * @dev First tries to call the ID function. If it exists, returns the vault ID. If it doesn't, performs a linear search through the implementations set.
     *      Reverts if the implementation is not found.
     */
    function _getVaultImplByImplementation(address implementation) private view returns (uint64) {
        // NOTE: without legacy this would be as simple as:
        // return IContractId(implementation).ID();
        // but some implementations do not implement this function.
        (uint64 vaultImpl, bool hasNoId) = _getIdOfContract(implementation);
        if (!hasNoId && CFBSLib.fetch().vaultImplToImplementation[vaultImpl] == implementation) return vaultImpl;
        // If ID() doesn't exist, failed, or returned 0/invalid, fall back to legacy
        return _getVaultImplByImplementationLegacy(implementation);
    }

    /**
     * @dev legacy Internal helper to find the vault ID for a given implementation address.
     * @param implementation The implementation address to find
     * @return vaultImpl The legacy vault ids were incremental starting with 1. The new vault ids are queried from the implementation's ID function.
     * @dev Performs a linear search through the legacyImplementationSet set.
     *      Reverts if the implementation is not found.
     */
    function _getVaultImplByImplementationLegacy(address implementation) private view returns (uint64) {
        CFBSLib.ConcreteFactoryBaseStorage storage $ = CFBSLib.fetch();
        uint256 length = $.legacyImplementationSet.length();

        for (uint256 i = 0; i < length; ++i) {
            if ($.legacyImplementationSet.at(i) == implementation) {
                return uint64(i + 1); // Convert to 1-indexed
            }
        }

        revert IConcreteFactory.ImplementationNotFound();
    }

    /**
     * @inheritdoc IConcreteFactory
     */
    function create(uint64 vaultImpl, address ownerAddr, bytes calldata data) external returns (address) {
        return create(vaultImpl, ownerAddr, data, bytes32(0));
    }

    /**
     * @inheritdoc IConcreteFactory
     */
    function create(uint64 vaultImpl, address ownerAddr, bytes calldata data, bytes32 salt) public returns (address) {
        address predictedAddress = predictVaultAddress(vaultImpl, ownerAddr, data, salt);

        CFBSLib.fetch().vaults[predictedAddress] = true;
        bytes memory bytecode = _computeBytecode(vaultImpl, ownerAddr, data);

        // Deploy using OpenZeppelin Create2
        address concreteVault = Create2.deploy(0, salt, bytecode);

        require(predictedAddress == concreteVault, InvalidVaultAddress());

        // Mark the vault as deployed by this factory

        emit Deployed(concreteVault, vaultImpl, ownerAddr);

        return concreteVault;
    }

    /**
     * @inheritdoc IConcreteFactory
     */
    function predictVaultAddress(uint64 vaultImpl, address ownerAddr, bytes calldata data)
        external
        view
        returns (address)
    {
        return predictVaultAddress(vaultImpl, ownerAddr, data, bytes32(0));
    }

    function _computeBytecode(uint64 vaultImpl, address ownerAddr, bytes calldata data)
        internal
        view
        returns (bytes memory)
    {
        require(!isBlocked(vaultImpl), ImplementationBlocked());

        // Get the implementation address
        address implementation = getImplementationByVaultImpl(vaultImpl);

        // Encode the constructor parameters - pass storage struct directly
        bytes memory constructorData =
            abi.encodeCall(IUpgradeableVault.initialize, (vaultImpl, ownerAddr, DEVCLib.fetch(), data));

        // Create the bytecode for deployment
        // Note: VAULT_PROXY_CREATION_CODE() returns the hardcoded creation code embedded in the factory's bytecode
        // If the factory is upgraded with a different compiler version, this value may change,
        // which could affect CREATE2 address determinism for new deployments
        // It is then recommended call the implementation's VAULT_PROXY_CREATION_CODE() function to get the correct creation code.
        return abi.encodePacked(VAULT_PROXY_CREATION_CODE(), abi.encode(implementation, constructorData));
    }

    /**
     * @dev Returns the VaultProxy creation code (hardcoded at compile time).
     * @return The creation code bytes embedded in the factory's bytecode
     */
    function VAULT_PROXY_CREATION_CODE() public pure returns (bytes memory) {
        return type(VaultProxy).creationCode;
    }

    /**
     * @inheritdoc IConcreteFactory
     */
    function predictVaultAddress(uint64 vaultImpl, address ownerAddr, bytes calldata data, bytes32 salt)
        public
        view
        returns (address)
    {
        bytes memory bytecode = _computeBytecode(vaultImpl, ownerAddr, data);

        // Compute CREATE2 address using OpenZeppelin
        return Create2.computeAddress(salt, keccak256(bytecode), address(this));
    }

    /**
     * @inheritdoc IConcreteFactory
     */
    function upgrade(address vault, uint64 newVaultImpl, bytes calldata data) external {
        _upgrade(vault, newVaultImpl, data);
    }

    /**
     * @inheritdoc IConcreteFactory
     */
    function batchUpgrade(address[] calldata vaultAddresses, uint64 newVaultImpl, bytes[] calldata data) external {
        require(vaultAddresses.length == data.length, InvalidDataLength());
        for (uint256 i = 0; i < vaultAddresses.length; i++) {
            _upgrade(vaultAddresses[i], newVaultImpl, data[i]);
        }
    }

    /**
     * @inheritdoc IConcreteFactory
     */
    function lastVersion() public view returns (uint64) {
        return uint64(CFBSLib.fetch().legacyImplementationSet.length());
    }

    /**
     * @notice This is a legacy function that has been downgraded to internal and is used as a fallback for getImplementationByVaultImpl.
     * @param version The version to get the implementation for
     * @return The implementation address
     * @dev This function is used as a fallback for getImplementationByVaultImpl.
     */
    function getImplementationByVersion(uint64 version) internal view returns (address) {
        return CFBSLib.fetch().legacyImplementationSet.at(version - 1);
    }

    /**
     * @inheritdoc IConcreteFactory
     */
    function getImplementationByVaultImpl(uint64 vaultImpl) public view returns (address) {
        CFBSLib.ConcreteFactoryBaseStorage storage $ = CFBSLib.fetch();
        address implementation = $.vaultImplToImplementation[vaultImpl];

        // If the mapping has an entry, return it
        if (implementation != address(0)) return implementation;

        // Otherwise fall back to legacy version-based lookup
        return getImplementationByVersion(vaultImpl);
    }

    /**
     * @inheritdoc IConcreteFactory
     */
    function isBlocked(uint64 vaultImpl) public view checkVersion(vaultImpl) returns (bool) {
        return CFBSLib.fetch().blocked[vaultImpl];
    }

    /**
     * @inheritdoc IConcreteFactory
     */
    function isMigratable(uint64 fromVaultImpl, uint64 toVaultImpl)
        public
        view
        checkVersion(fromVaultImpl)
        checkVersion(toVaultImpl)
        returns (bool)
    {
        return CFBSLib.fetch().migratable[fromVaultImpl][toVaultImpl];
    }

    /**
     * @notice Check if a vault was deployed by this factory
     * @param vault The vault address to check
     * @return True if the vault was deployed by this factory, false otherwise
     */
    function isRegisteredVault(address vault) public view returns (bool) {
        return CFBSLib.fetch().vaults[vault];
    }

    /**
     * @dev Admin function to register an external vault proxy to be managed by this factory
     * useful in case of pre-v2 migrations
     * @param vault The vault address to register
     */
    function registerVault(address vault) external onlyOwner {
        require(vault != address(0), ZeroAddress());
        require(!CFBSLib.fetch().vaults[vault], VaultAlreadyRegistered());
        require(IUpgradeableVault(vault).factory() == address(this), InvalidImplementation());

        CFBSLib.fetch().vaults[vault] = true;

        emit VaultRegistered(vault);
    }

    /**
     * @inheritdoc IConcreteFactory
     */
    function setDefaultEnforcedVaultConfiguration(address managementFeeRecipient, address performanceFeeRecipient)
        external
        onlyOwner
    {
        require(managementFeeRecipient != address(0), ZeroAddress());
        require(performanceFeeRecipient != address(0), ZeroAddress());

        IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration storage feeConfig = DEVCLib.fetch();
        feeConfig.defaultManagementFeeRecipient = managementFeeRecipient;
        feeConfig.defaultPerformanceFeeRecipient = performanceFeeRecipient;

        emit DefaultEnforcedVaultConfigurationUpdated(managementFeeRecipient, performanceFeeRecipient);
    }

    /**
     * @inheritdoc IConcreteFactory
     */
    function getDefaultEnforcedVaultConfiguration()
        external
        view
        returns (address defaultManagementFeeRecipient, address defaultPerformanceFeeRecipient)
    {
        IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration storage feeConfig = DEVCLib.fetch();
        return (feeConfig.defaultManagementFeeRecipient, feeConfig.defaultPerformanceFeeRecipient);
    }

    /**
     * @dev Internal function to upgrade a vault to a new implementation version
     * @param vault The vault address to upgrade
     * @param newVaultImpl The target implementation vault ID
     * @param data Custom data to pass to the new implementation's upgrade function
     */
    function _upgrade(address vault, uint64 newVaultImpl, bytes calldata data) internal {
        // check guards
        require(isRegisteredVault(vault), NotRegisteredVault());
        require(msg.sender == OwnableUpgradeable(vault).owner(), NotOwner());
        // initialize variables
        uint64 currentVaultImpl = 0;
        bool newVaultIsLegacy = false;
        // load migration conditions
        (currentVaultImpl,) = _getVaultImplOfRegisteredVault(vault);
        (, newVaultIsLegacy) = _isValidVaultImpl(newVaultImpl);
        bool versionCondition = newVaultIsLegacy ? currentVaultImpl < newVaultImpl : currentVaultImpl != newVaultImpl;
        // check migration conditions
        require(versionCondition, OldVersion());
        require(isMigratable(currentVaultImpl, newVaultImpl), CanNotMigrate());
        require(!isBlocked(newVaultImpl), ImplementationBlocked());

        // perform upgrade
        IVaultProxy(vault)
            .upgradeToAndCall(
                getImplementationByVaultImpl(newVaultImpl),
                abi.encodeCall(IUpgradeableVault.upgrade, (newVaultImpl, data))
            );

        // emit event
        emit Migrated(vault, newVaultImpl);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
