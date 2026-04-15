// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

/**
 * @title AbstractUpgradeableVault
 * @notice Abstract upgradeable base for Concrete vault implementations.
 *         Provides initializer pattern, ownership, and reentrancy guards.
 *
 * @author Blueprint Finance
 * @custom:protocol Concrete Earn V2
 * @custom:source on request
 * @custom:audits on request
 * @custom:license  AGPL-3.0
 */

// ─────────────────────────────────────────────────────────────────────────────
// External dependencies
// ─────────────────────────────────────────────────────────────────────────────
import {Initializable} from "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Protocol-facing interfaces
// ─────────────────────────────────────────────────────────────────────────────
import {IDefaultEnforcedVaultConfiguration} from "../interface/IDefaultEnforcedVaultConfiguration.sol";
import {IUpgradeableVault} from "../interface/IUpgradeableVault.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Storage layout libraries
// ─────────────────────────────────────────────────────────────────────────────
abstract contract UpgradeableVault is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, IUpgradeableVault {
    address public immutable factory;

    /**
     * @notice Get the contract's ID.
     * @return ID of the contract
     * @dev This is a virtual function that must be overridden by concrete implementations.
     *      Concrete implementations should also implement IContractId interface.
     */
    function ID() public pure virtual returns (uint64);

    constructor(address factoryAddr) {
        _disableInitializers();

        factory = factoryAddr;
    }

    modifier notInitialized() {
        if (_getInitializedVersion() != 0) {
            revert AlreadyInitialized();
        }

        _;
    }

    /**
     * @inheritdoc IUpgradeableVault
     */
    function version() public view returns (uint64) {
        return _getInitializedVersion();
    }

    /**
     * @inheritdoc IUpgradeableVault
     */
    function initialize(
        uint64 initialVaultImpl,
        address owner_,
        IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration calldata defaultEnforcedVaultConfig,
        bytes calldata data
    ) external notInitialized initializer {
        require(_msgSender() == factory, NotFactory());
        require(initialVaultImpl == ID(), InvalidVaultImpl());

        __ReentrancyGuard_init();

        __Ownable_init(owner_);

        _initialize(initialVaultImpl, owner_, defaultEnforcedVaultConfig, data);
    }

    /**
     * @inheritdoc IUpgradeableVault
     */
    function upgrade(uint64 newVaultImpl, bytes calldata data)
        external
        nonReentrant
        reinitializer(_getInitializedVersion() + 1)
    {
        require(_msgSender() == factory, NotFactory());
        require(newVaultImpl == ID(), InvalidVaultImpl());
        _upgrade(newVaultImpl, data);
    }

    /**
     *
     * @param initialVaultImpl initial vault ID from the factory
     * @param owner vault proxy owner address
     * @param defaultEnforcedVaultConfig default configuration from the factory
     * @param data arbitrary data used to initialize a proxy implementation
     */
    function _initialize(
        uint64 initialVaultImpl,
        address owner,
        IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration calldata defaultEnforcedVaultConfig,
        bytes memory data
    ) internal virtual {}

    /**
     *
     * @param newVaultImpl vault proxy new vault ID
     * @param data arbitrary data that will be used on the new `newImplementation.upgrade()` function to execute the upgrade flow
     */
    function _upgrade(uint64 newVaultImpl, bytes calldata data) internal virtual {}
}
