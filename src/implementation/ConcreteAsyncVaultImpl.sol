// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

/**
 * @title ConcreteAsyncVaultImpl
 * @notice ERC-4626-compatible, upgradeable async vault implementation that inherits the standard vault
 *         implementation and adds delayed/batched settlement flows for integrations where
 *         strategies have liquidity latency or epoch-based processing.
 *
 * @author Blueprint Finance
 * @custom:protocol Concrete Earn V2
 * @custom:oz-upgrades Use OZ Upgradeable patterns and eip7201 storage layout
 * @custom:source on request
 * @custom:audits on request
 * @custom:license AGPL-3.0
 */

// ─────────────────────────────────────────────────────────────────────────────
// External dependencies
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Protocol-facing interfaces
// ─────────────────────────────────────────────────────────────────────────────
import {IContractId} from "../interface/IContractId.sol";
import {IConcreteAsyncVaultImpl} from "../interface/IConcreteAsyncVaultImpl.sol";
import {IConcreteStandardVaultImpl} from "../interface/IConcreteStandardVaultImpl.sol";
import {IDefaultEnforcedVaultConfiguration} from "../interface/IDefaultEnforcedVaultConfiguration.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Internal contracts
// ─────────────────────────────────────────────────────────────────────────────
import {ConcreteStandardVaultImpl} from "./ConcreteStandardVaultImpl.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Internal libraries
// ─────────────────────────────────────────────────────────────────────────────
import {AsyncVaultHelperLib} from "../lib/AsyncVaultHelperLib.sol";
import {ConcreteV2ConversionLib as ConversionLib} from "../lib/Conversion.sol";
import {
    ConcreteCachedVaultStateStorageLib as CachedVaultStateLib
} from "../lib/storage/ConcreteCachedVaultStateStorageLib.sol";
import {ConcreteV2RolesLib as RolesLib} from "../../src/lib/Roles.sol";
import {StateInitLib} from "../lib/StateInitLib.sol";
import {StateSetterLib} from "../lib/StateSetterLib.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Storage layout libraries
// ─────────────────────────────────────────────────────────────────────────────
import {ConcreteAsyncVaultImplStorageLib} from "../lib/storage/ConcreteAsyncVaultImplStorageLib.sol";
import {ContractIdEncoding} from "../lib/ContractIdEncoding.sol";

contract ConcreteAsyncVaultImpl is ConcreteStandardVaultImpl, IConcreteAsyncVaultImpl {
    function FLAVOUR() public pure virtual override returns (uint256) {
        return 2; // async vault
    }

    function ID() public pure virtual override(ConcreteStandardVaultImpl) returns (uint64) {
        return ContractIdEncoding.encode(CONTRACT_TYPE, FLAVOUR(), 1, 7, 0);
    }

    constructor(address factory) ConcreteStandardVaultImpl(factory) {}

    /**
     * @dev Override _initialize to set up async vault specific state
     */
    function _initialize(
        uint64 initialVersion,
        address owner,
        IDefaultEnforcedVaultConfiguration.DefaultEnforcedVaultConfiguration calldata defaultEnforcedVaultConfig,
        bytes memory data
    ) internal virtual override {
        super._initialize(initialVersion, owner, defaultEnforcedVaultConfig, data);

        address initialVaultManager;
        assembly {
            initialVaultManager := mload(add(data, 0x60))
        }
        __ConcreteAsyncVaultImpl_init(initialVaultManager);
    }

    /**
     * @notice Initializes the WithdrawalQueueModule
     * @dev Sets the initial epoch ID to 1 and emits initialization event
     */
    function __ConcreteAsyncVaultImpl_init(address initialVaultManager) internal onlyInitializing {
        StateInitLib.stateInitAsyncVaultImpl(initialVaultManager, _msgSender());
    }

    /**
     * @dev Upgrade hook for vaults migrating to this implementation.
     *
     * All upgrade-time work (legacy role migration + idempotent async-specific state
     * init gated on `latestEpochID == 0`) is delegated to `StateInitLib` to keep the
     * runtime bytecode of this contract — and of `ConcreteBridgedAsyncVaultImpl`,
     * which inherits it — under the EIP-170 limit. The library runs in the proxy's
     * storage context via DELEGATECALL.
     */
    function _upgrade(uint64, bytes calldata data) internal virtual override whenNotPaused {
        StateInitLib.stateUpgradeAsyncVaultImpl(data);
    }

    /// @inheritdoc IConcreteAsyncVaultImpl
    function toggleQueueActive() external virtual onlyRole(RolesLib.VAULT_MANAGER) {
        AsyncVaultHelperLib.toggleQueueActive();
    }

    /// @inheritdoc IConcreteAsyncVaultImpl
    function cancelRequest(uint256 epochID) external virtual whenNotPaused {
        AsyncVaultHelperLib.cancelRequest(_msgSender(), epochID);
    }

    /// @inheritdoc IConcreteAsyncVaultImpl
    function cancelRequest(address user, uint256 epochID)
        external
        virtual
        whenNotPaused
        onlyRole(RolesLib.WITHDRAWAL_MANAGER)
    {
        AsyncVaultHelperLib.cancelRequest(user, epochID);
    }

    function closeEpoch() external virtual whenNotPaused onlyRole(RolesLib.WITHDRAWAL_MANAGER) {
        AsyncVaultHelperLib.closeEpoch();
    }

    /// @inheritdoc IConcreteAsyncVaultImpl
    function processEpoch()
        external
        virtual
        whenNotPaused
        withYieldAccrual
        nonReentrant
        onlyRole(RolesLib.WITHDRAWAL_MANAGER)
    {
        AsyncVaultHelperLib.processEpoch(_lockedAssets(), decimals());
    }

    /// @inheritdoc IConcreteAsyncVaultImpl
    function processPartialEpochRequest(address user, uint256 epochID, uint256 amount)
        external
        virtual
        whenNotPaused
        withYieldAccrual
        nonReentrant
        onlyRole(RolesLib.WITHDRAWAL_MANAGER)
    {
        AsyncVaultHelperLib.processPartialEpochRequest(_lockedAssets(), user, epochID, amount, decimals());
    }

    // External view functions

    /// @inheritdoc IConcreteAsyncVaultImpl
    function getUserEpochRequestInAssets(address user, uint256 epochID) external view virtual returns (uint256 assets) {
        return AsyncVaultHelperLib.getUserEpochRequestInAssetsView(user, epochID, decimals());
    }

    // Public functions
    /// @inheritdoc IConcreteAsyncVaultImpl

    function claimWithdrawal(uint256[] calldata epochIDs) external virtual whenNotPaused {
        AsyncVaultHelperLib.claimWithdrawal(_msgSender(), epochIDs, decimals());
    }

    /// @inheritdoc IConcreteAsyncVaultImpl
    function claimWithdrawal(address user, uint256[] calldata epochIDs)
        external
        virtual
        whenNotPaused
        onlyRole(RolesLib.WITHDRAWAL_MANAGER)
    {
        AsyncVaultHelperLib.claimWithdrawal(user, epochIDs, decimals());
    }

    /**
     * @notice Claims the processed withdrawal requests of several users for one epoch and sends
     *         each user their assets.
     * @dev Only callable by the WITHDRAWAL_MANAGER role, and only while the vault is not paused.
     *      Users without a claimable request in the epoch are skipped. Reverts with `EmptyUsers` for an
     *      empty list, `EpochNotProcessed` if the epoch is not processed yet, and `NoClaimableRequest`
     *      if nothing was claimed. Emits `RequestClaimed` per paid-out user.
     * @param users The users whose requests are claimed
     * @param epochID The processed epoch to claim from
     */
    function claimUsersBatch(address[] calldata users, uint256 epochID)
        external
        virtual
        whenNotPaused
        onlyRole(RolesLib.WITHDRAWAL_MANAGER)
    {
        AsyncVaultHelperLib.claimUsersBatch(users, epochID, decimals());
    }

    function claimPriorityWithdrawal(address user, uint256 sharesToFulfil, uint256 unwindCost, address strategy)
        external
        virtual
        whenNotPaused
        withYieldAccrual
        nonReentrant
        onlyRole(RolesLib.PRIORITY_WITHDRAWAL_EXECUTOR)
    {
        AsyncVaultHelperLib.claimPriorityWithdrawal(user, sharesToFulfil, unwindCost, _lockedAssets(), strategy);
    }

    /// @inheritdoc IConcreteAsyncVaultImpl
    function moveRequestToNextEpoch(address user, uint256 fromEpochID, uint256 amount)
        external
        whenNotPaused
        onlyRole(RolesLib.WITHDRAWAL_MANAGER)
    {
        AsyncVaultHelperLib.moveRequestToNextEpoch(user, fromEpochID, amount);
    }

    /// @inheritdoc IConcreteAsyncVaultImpl
    function getUserEpochRequest(address user, uint256 epochID) external view virtual returns (uint256 shares) {
        return ConcreteAsyncVaultImplStorageLib.fetch().userEpochRequests[user][epochID];
    }

    /// @inheritdoc IConcreteAsyncVaultImpl
    function latestEpochID() external view virtual returns (uint256) {
        return ConcreteAsyncVaultImplStorageLib.fetch().latestEpochID;
    }

    /// @inheritdoc IConcreteAsyncVaultImpl
    function pastEpochsUnclaimedAssets() external view virtual returns (uint256) {
        return ConcreteAsyncVaultImplStorageLib.fetch().pastEpochsUnclaimedAssets;
    }

    /// @inheritdoc IConcreteAsyncVaultImpl
    function totalRequestedSharesPerEpoch(uint256 epochID) external view virtual returns (uint256) {
        return ConcreteAsyncVaultImplStorageLib.fetch().totalRequestedSharesPerEpoch[epochID];
    }

    /// @inheritdoc IConcreteAsyncVaultImpl
    function totalRequestedSharesForCurrentEpochs() external view virtual returns (uint256, uint256, uint256) {
        return AsyncVaultHelperLib.totalRequestedSharesForCurrentEpochs();
    }

    /// @inheritdoc IConcreteAsyncVaultImpl
    function getEpochPricePerShare(uint256 epochID) public view virtual returns (uint256) {
        uint256 epochPricePlusOne = ConcreteAsyncVaultImplStorageLib.fetch().epochPricePerSharePlusOne[epochID];
        if (epochPricePlusOne == 0) return 0;
        return epochPricePlusOne - 1;
    }

    function getEpochState(uint256 epochID) external view virtual returns (EpochState) {
        return AsyncVaultHelperLib.getEpochState(epochID);
    }

    // Internal functions
    /**
     * @dev Override _executeWithdraw to implement async withdrawal pattern
     * @dev This is called by parent's withdraw() and redeem() after harvest and validation
     * @dev Instead of immediately transferring assets, we queue the request for epoch processing
     */
    function _executeWithdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
        returns (uint256)
    {
        if (ConcreteAsyncVaultImplStorageLib.fetch().isQueueActive) {
            return AsyncVaultHelperLib.executeQueuedWithdraw(caller, receiver, owner, assets, shares);
        }
        return super._executeWithdraw(caller, receiver, owner, assets, shares);
    }

    /// @inheritdoc IConcreteAsyncVaultImpl
    function isQueueActive() external view virtual returns (bool) {
        return ConcreteAsyncVaultImplStorageLib.fetch().isQueueActive;
    }

    /// @inheritdoc IConcreteStandardVaultImpl
    function cancellationEnabled()
        external
        view
        virtual
        override(ConcreteStandardVaultImpl, IConcreteStandardVaultImpl)
        returns (bool)
    {
        return !ConcreteAsyncVaultImplStorageLib.fetch().cancellationDisabled;
    }

    function _lockedAssets() internal view override returns (uint256) {
        return ConcreteAsyncVaultImplStorageLib.fetch().pastEpochsUnclaimedAssets;
    }

    /// @inheritdoc IConcreteAsyncVaultImpl
    function getUnwindCostCap() external view virtual returns (uint16) {
        return ConcreteAsyncVaultImplStorageLib.fetch().unwindCostCapBP;
    }

    /// @inheritdoc IConcreteAsyncVaultImpl
    function setUnwindCostCap(uint16 unwindCostCap_) external virtual afterDelay onlyRole(RolesLib.VAULT_MANAGER) {
        StateSetterLib.setUnwindCostCap(unwindCostCap_);
    }
}
