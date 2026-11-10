// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BaseStrategy} from "./BaseStrategy.sol";
import {ContractIdEncoding} from "../../lib/ContractIdEncoding.sol";
import {BaseStrategyStorageLib as BaseStrategyStorage} from "../lib/BaseStrategyStorageLib.sol";
import {MultisigStrategyStorageLib as MultisigStrategyStorage} from "../lib/MultisigStrategyStorageLib.sol";
import {PositionAccountingStorageLib} from "../lib/PositionAccountingStorageLib.sol";
import {PositionAccountingLib} from "../lib/PositionAccountingLib.sol";
import {PeripheryRolesLib} from "../lib/PeripheryRolesLib.sol";
import {StrategyType} from "../../interface/IStrategyTemplate.sol";
import {IAsyncAccounting} from "../../interface/IAsyncAccounting.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {SignedMath} from "@openzeppelin-contracts/utils/math/SignedMath.sol";

/**
 * @title MultisigStrategy
 * @dev A strategy that forwards assets to a designated multi-signature wallet
 * @dev Implements BaseStrategy for integration with the vault system
 * @dev This strategy simply forwards deposits to a multi-sig wallet and retrieves
 *      them on withdrawal. It does not generate any rewards.
 * @dev Uses EIP-7201 storage layout for upgradeability.
 */
contract MultisigStrategy is BaseStrategy, IAsyncAccounting {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using SafeCast for int256;
    using SignedMath for int256;

    /// @notice Emitted when the multi-sig is set
    /// @param multiSig The address of the multi-sig wallet
    /// @param newMultiSig The new address of the multi-sig wallet
    event MultiSigSet(address indexed multiSig, address indexed newMultiSig);

    /// @notice Emitted when a multi-sig transfer is started (2-step propose).
    /// @param multiSig The current (still active) multi-sig wallet
    /// @param pendingMultiSig The proposed multi-sig wallet pending acceptance
    event MultiSigTransferStarted(address indexed multiSig, address indexed pendingMultiSig);

    /// @notice Emitted when assets are forwarded to the multi-sig
    /// @param multiSig The address of the multi-sig wallet
    /// @param asset The address of the asset forwarded
    /// @param amount The amount of assets forwarded
    event AssetsForwarded(address indexed multiSig, address asset, uint256 amount);

    /// @notice Emitted when assets are retrieved from the multi-sig
    /// @param multiSig The address of the multi-sig wallet
    /// @param asset The address of the asset retrieved
    /// @param amount The amount of assets retrieved
    event AssetsRetrieved(address indexed multiSig, address asset, uint256 amount);

    /// @notice Emitted when the total assets are adjusted
    /// @param accountingNonce The accounting nonce
    /// @param totalAssets The new total assets
    /// @param diff The amount of underlying assets to adjust the total assets by
    event AdjustTotalAssets(uint256 accountingNonce, uint256 totalAssets, int256 diff);

    /// @notice Custom errors
    error InvalidMultiSigAddress();
    error InsufficientUnderlyingBalance();
    error NotAdminOrOperator();
    /// @notice Thrown when `acceptMultiSig` is called by an address other than the pending multi-sig.
    error NotPendingMultiSig();

    /// @notice Modifier to ensure only admin or operator can call functions
    modifier onlyAdminOrOperator() {
        if (
            !hasRole(PeripheryRolesLib.STRATEGY_ADMIN, msg.sender)
                && !hasRole(PeripheryRolesLib.OPERATOR_ROLE, msg.sender)
        ) {
            revert NotAdminOrOperator();
        }
        _;
    }

    function FLAVOUR() public pure virtual returns (uint256) {
        return 2; // multisig strategy
    }

    /**
     * @notice Returns the contract ID
     * @return The contract ID
     */
    function ID() public pure virtual override(BaseStrategy) returns (uint64) {
        return ContractIdEncoding.encode(CONTRACT_TYPE, FLAVOUR(), 1, 6, 0);
    }

    /**
     * @dev Constructor that disables initializers
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializer function
     * @param admin The address that will have admin role
     * @param vault_ The address of the authorized vault
     * @param multiSig_ The address of the multi-signature wallet
     * @param maxAccountingChangeThreshold_ The maximum accounting change threshold in basis points
     * @param accountingValidityPeriod_ The accounting validity period in seconds
     * @param cooldownPeriod_ The update cooldown period in seconds
     * @param timelock_ Address of the Timelock contract. Pass `address(0)` to
     *                  deploy without timelock enforcement.
     */
    function initialize(
        address admin,
        address vault_,
        address multiSig_,
        uint64 maxAccountingChangeThreshold_,
        uint64 accountingValidityPeriod_,
        uint64 cooldownPeriod_,
        address timelock_
    ) external initializer {
        __MultisigStrategy_init(
            admin,
            vault_,
            multiSig_,
            maxAccountingChangeThreshold_,
            accountingValidityPeriod_,
            cooldownPeriod_,
            timelock_
        );
    }

    function __MultisigStrategy_init(
        address admin,
        address vault_,
        address multiSig_,
        uint64 maxAccountingChangeThreshold_,
        uint64 accountingValidityPeriod_,
        uint64 cooldownPeriod_,
        address timelock_
    ) internal onlyInitializing {
        if (multiSig_ == address(0)) revert InvalidMultiSigAddress();
        if (cooldownPeriod_ < PositionAccountingLib.MIN_COOLDOWN_PERIOD) {
            revert PositionAccountingLib.InvalidCooldownPeriod();
        }
        if (accountingValidityPeriod_ < cooldownPeriod_ + PositionAccountingLib.MIN_PERIOD_DIFFERENCE) {
            revert PositionAccountingLib.InvalidAccountingValidityPeriod();
        }
        if (maxAccountingChangeThreshold_ > PositionAccountingLib.MAX_ACCOUNTING_CHANGE_THRESHOLD_CAP) {
            revert PositionAccountingLib.InvalidMaxAccountingChangeThreshold();
        }

        // Initialize BaseStrategy first
        __BaseStrategy_init(admin, vault_, timelock_);

        // Initialize MultisigStrategyStorage
        MultisigStrategyStorage.initialize(multiSig_);

        // Initialize PositionAccountingStorage
        PositionAccountingStorageLib.initialize(
            cooldownPeriod_, maxAccountingChangeThreshold_, accountingValidityPeriod_
        );
    }

    /**
     * GETTER FUNCTIONS
     */

    /**
     * @notice Returns the address of the multi-signature wallet
     * @return The address of the multi-signature wallet
     */
    function getMultiSig() external view returns (address) {
        MultisigStrategyStorage.MultisigStrategyStorage storage multisigStrategyStorage =
            MultisigStrategyStorage.fetch();
        return multisigStrategyStorage.multiSig;
    }

    /**
     * @notice Returns the proposed multi-sig wallet pending acceptance.
     * @return The address of the pending multi-sig wallet (zero if none pending)
     */
    function getPendingMultiSig() external view returns (address) {
        MultisigStrategyStorage.MultisigStrategyStorage storage multisigStrategyStorage =
            MultisigStrategyStorage.fetch();
        return multisigStrategyStorage.pendingMultiSig;
    }

    /**
     * @notice Returns the next accounting nonce
     * @return The next accounting nonce
     */
    function getNextAccountingNonce() public view returns (uint256) {
        return PositionAccountingLib.getNextAccountingNonce();
    }

    /**
     * @notice Returns whether an address has the operator role
     * @param account The address to check
     * @return True if the address has the operator role
     */
    function isOperator(address account) external view returns (bool) {
        return hasRole(PeripheryRolesLib.OPERATOR_ROLE, account);
    }

    /**
     * @notice Returns the last updated timestamp
     * @return The last updated timestamp
     */
    function getLastUpdatedTimestamp() external view returns (uint64) {
        return PositionAccountingLib.getLastUpdatedTimestamp();
    }

    /**
     * @notice Returns the max accounting change threshold
     * @return The max accounting change threshold
     */
    function getMaxAccountingChangeThreshold() external view returns (uint64) {
        return PositionAccountingLib.getMaxAccountingChangeThreshold();
    }

    /**
     * @notice Returns the accounting validity period
     * @return The accounting validity period
     */
    function getAccountingValidityPeriod() external view returns (uint64) {
        return PositionAccountingLib.getAccountingValidityPeriod();
    }

    /**
     * @notice Returns the update cooldown period
     * @return The update cooldown period
     */
    function getCooldownPeriod() external view returns (uint64) {
        return PositionAccountingLib.getCooldownPeriod();
    }

    /**
     * @dev Override strategyType for MultisigStrategy
     * @dev MultisigStrategy is an async strategy that requires multisig approval for operations
     * @return ASYNC strategy type
     */
    function strategyType() external pure override returns (StrategyType) {
        return StrategyType.ASYNC;
    }

    /**
     * SETTER FUNCTIONS
     */

    /**
     * @notice Proposes a new multi-signature wallet (first step of a 2-step transfer).
     * @param multiSig_ The address of the proposed multi-signature wallet
     * @dev Mirrors {Ownable2Step-transferOwnership}: this only records the pending
     *      multi-sig; the active multi-sig is unchanged until {acceptMultiSig} is
     *      called by `multiSig_`. Calling again overwrites any pending proposal.
     * @dev The multiSig must approve this contract to pull funds for withdrawals.
     */
    function setMultiSig(address multiSig_) external onlyRole(PeripheryRolesLib.STRATEGY_ADMIN) afterDelay {
        if (multiSig_ == address(0)) revert InvalidMultiSigAddress();
        MultisigStrategyStorage.MultisigStrategyStorage storage multisigStrategyStorage =
            MultisigStrategyStorage.fetch();
        multisigStrategyStorage.pendingMultiSig = multiSig_;
        emit MultiSigTransferStarted(multisigStrategyStorage.multiSig, multiSig_);
    }

    /**
     * @notice Accepts a pending multi-sig transfer (second step of a 2-step transfer).
     * @dev Mirrors {Ownable2Step-acceptOwnership}: callable only by the pending
     *      multi-sig. Finalizes the transfer and clears the pending slot. Not
     *      timelock-gated; the delay is enforced on {setMultiSig}.
     */
    function acceptMultiSig() external {
        MultisigStrategyStorage.MultisigStrategyStorage storage multisigStrategyStorage =
            MultisigStrategyStorage.fetch();
        require(msg.sender == multisigStrategyStorage.pendingMultiSig, NotPendingMultiSig());
        emit MultiSigSet(multisigStrategyStorage.multiSig, msg.sender);
        multisigStrategyStorage.multiSig = msg.sender;
        delete multisigStrategyStorage.pendingMultiSig;
    }

    /**
     * @notice Sets the max accounting change threshold
     * @param maxAccountingChangeThreshold_ The maximum accounting change threshold in basis points (10000 = 100%, 100 = 1%)
     */
    function setMaxAccountingChangeThreshold(uint64 maxAccountingChangeThreshold_)
        external
        onlyRole(PeripheryRolesLib.STRATEGY_ADMIN)
        afterDelay
    {
        PositionAccountingLib.setMaxAccountingChangeThreshold(maxAccountingChangeThreshold_);
    }

    /**
     * @notice Sets the accounting change validation period
     * @param accountingValidityPeriod_ The new accounting change validation period in seconds
     */
    function setAccountingValidityPeriod(uint64 accountingValidityPeriod_)
        external
        onlyRole(PeripheryRolesLib.STRATEGY_ADMIN)
    {
        PositionAccountingLib.setAccountingValidityPeriod(accountingValidityPeriod_);
    }

    /**
     * @notice Sets the accounting update cooldown period
     * @param cooldownPeriod_ The new update cooldown period in seconds
     */
    function setCooldownPeriod(uint64 cooldownPeriod_) external onlyRole(PeripheryRolesLib.STRATEGY_ADMIN) afterDelay {
        PositionAccountingLib.setCooldownPeriod(cooldownPeriod_);
    }

    /**
     * ADMIN STATE MODIFYING FUNCTIONS
     */

    /**
     * @notice Unpauses the strategy and adjusts the total assets
     * @dev Can only be called by the owner
     * @dev Skips the validation of the accounting change, used by the admin multisig to fix the accounting when the strategy is paused
     * @dev Allows the admin to correct the accounting when the strategy is paused in a single transaction even if the change exceeds the max accounting change threshold
     * @param diff The amount of underlying assets to adjust the total assets by
     */
    function unpauseAndAdjustTotalAssets(int256 diff) external onlyRole(PeripheryRolesLib.STRATEGY_ADMIN) {
        _unpause();
        _adjustTotalAssets(diff);
    }

    /**
     * @notice Handles the accounting for the amount of underlying assets owned by the multisig wallet and by its positions.
     * @param diff The amount of underlying assets to adjust the total assets by
     */
    function adjustTotalAssets(int256 diff, uint256 accountingNonce_) external whenNotPaused onlyAdminOrOperator {
        MultisigStrategyStorage.MultisigStrategyStorage storage multisigStrategyStorage =
            MultisigStrategyStorage.fetch();

        // Validate the accounting change
        if (!PositionAccountingLib.isValidAccountingChange(
                diff, accountingNonce_, multisigStrategyStorage.vaultDepositedAmount
            )) {
            _pause();
            return;
        }

        // Adjust the total assets
        _adjustTotalAssets(diff);
    }

    /**
     * @notice Vault-initiated accounting adjustment (e.g. recording an unwind cost).
     * @dev Callable only by the bound vault. Bypasses nonce / threshold / cooldown
     *      checks because the vault is a trusted caller.
     * @param diff Signed delta applied to the strategy's vaultDepositedAmount.
     */
    function adjustTotalAssets(int256 diff) external override onlyVault {
        _adjustTotalAssets(diff);
    }

    /**
     * INTERNAL FUNCTIONS
     */

    /**
     * @dev function to preview the current position value
     * @return The current vault deposited amount
     */
    function _previewPosition() internal view override returns (uint256) {
        // Check accounting validity period
        PositionAccountingLib._checkAccountingValidity();

        MultisigStrategyStorage.MultisigStrategyStorage storage multisigStrategyStorage =
            MultisigStrategyStorage.fetch();
        return multisigStrategyStorage.vaultDepositedAmount;
    }

    /**
     * @dev function to allocate funds to the position
     * @param data The data containing the amount to allocate
     * @return The actual amount allocated
     */
    function _allocateToPosition(bytes calldata data) internal override whenNotPaused returns (uint256) {
        uint256 amount;
        assembly {
            amount := calldataload(data.offset)
        }

        PositionAccountingLib._checkAccountingValidity();
        MultisigStrategyStorage.MultisigStrategyStorage storage multisigStrategyStorage =
            MultisigStrategyStorage.fetch();
        multisigStrategyStorage.vaultDepositedAmount += amount;

        BaseStrategyStorage.BaseStrategyStorage storage baseStrategyStorage = BaseStrategyStorage.fetch();
        IERC20(baseStrategyStorage.asset).safeTransfer(multisigStrategyStorage.multiSig, amount);
        emit AssetsForwarded(multisigStrategyStorage.multiSig, baseStrategyStorage.asset, amount);

        return amount;
    }

    /**
     * @dev Internal function to retrieve assets from the multisig
     * @param amount The amount of assets to retrieve
     * @return The actual amount retrieved
     */
    function _retrieveAssetsFromMultisig(uint256 amount) internal whenNotPaused returns (uint256) {
        PositionAccountingLib._checkAccountingValidity();

        MultisigStrategyStorage.MultisigStrategyStorage storage multisigStrategyStorage =
            MultisigStrategyStorage.fetch();

        if (amount > multisigStrategyStorage.vaultDepositedAmount) revert InsufficientUnderlyingBalance();
        multisigStrategyStorage.vaultDepositedAmount -= amount;

        BaseStrategyStorage.BaseStrategyStorage storage baseStrategyStorage = BaseStrategyStorage.fetch();
        IERC20(baseStrategyStorage.asset).safeTransferFrom(multisigStrategyStorage.multiSig, address(this), amount);
        emit AssetsRetrieved(multisigStrategyStorage.multiSig, baseStrategyStorage.asset, amount);

        return amount;
    }

    /**
     * @dev  function to deallocate funds from the position
     * @param data The data containing the amount to deallocate
     * @return The actual amount deallocated
     */
    function _deallocateFromPosition(bytes calldata data) internal override returns (uint256) {
        uint256 amount;
        assembly {
            amount := calldataload(data.offset)
        }
        return _retrieveAssetsFromMultisig(amount);
    }

    /**
     * @dev function to withdraw funds from the position
     * @param assets The amount of assets to withdraw
     * @return The actual amount withdrawn
     */
    function _withdrawFromPosition(uint256 assets) internal override returns (uint256) {
        return _retrieveAssetsFromMultisig(assets);
    }

    /**
     * @notice Internal function to adjust total assets
     * @param diff The amount of underlying assets to adjust the total assets by
     */
    function _adjustTotalAssets(int256 diff) internal {
        MultisigStrategyStorage.MultisigStrategyStorage storage multisigStrategyStorage =
            MultisigStrategyStorage.fetch();

        // Update timestamp and nonce
        uint256 newNonce = PositionAccountingLib.updateTimestampAndNonce();

        if (diff < 0) {
            uint256 absDiff = uint256(-diff);
            if (absDiff > multisigStrategyStorage.vaultDepositedAmount) revert InsufficientUnderlyingBalance();
            multisigStrategyStorage.vaultDepositedAmount -= absDiff;
        } else {
            multisigStrategyStorage.vaultDepositedAmount += uint256(diff);
        }
        emit AdjustTotalAssets(newNonce, multisigStrategyStorage.vaultDepositedAmount, diff);
    }
}
