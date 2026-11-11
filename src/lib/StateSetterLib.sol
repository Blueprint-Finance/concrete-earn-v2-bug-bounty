// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ConcreteStandardVaultImplStorageLib as SVLib} from "./storage/ConcreteStandardVaultImplStorageLib.sol";
import {
    ConcreteCachedVaultStateStorageLib as CachedVaultStateLib
} from "./storage/ConcreteCachedVaultStateStorageLib.sol";
import {IStrategyTemplate} from "../interface/IStrategyTemplate.sol";
import {ConcreteAsyncVaultImplStorageLib as AVLib} from "./storage/ConcreteAsyncVaultImplStorageLib.sol";
import {
    ConcreteMultiAssetDepositAsyncVaultStorageLib as MASLib
} from "./storage/ConcreteMultiAssetDepositAsyncVaultStorageLib.sol";
import {EnumerableSet} from "@openzeppelin-contracts/utils/structs/EnumerableSet.sol";
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";
import {IConcreteStandardVaultImpl} from "../interface/IConcreteStandardVaultImpl.sol";
import {IConcreteAsyncVaultImpl} from "../interface/IConcreteAsyncVaultImpl.sol";
import {IConcreteMultiAssetDepositAsyncVault as IMAV} from "../interface/IConcreteMultiAssetDepositAsyncVault.sol";
import {IHurdleRateOracle} from "../interface/IHurdleRateOracle.sol";
import {IHook, Hooks} from "../interface/IHook.sol";
import {ConcreteV2FeeParamsLib} from "./Constants.sol";
import {AsyncVaultHelperLib} from "./AsyncVaultHelperLib.sol";

library StateSetterLib {
    using EnumerableSet for EnumerableSet.AddressSet;

    function updateManagementFee(uint16 managementFee_) public {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        if (managementFee_ > 0) {
            require($.managementFeeRecipient != address(0), IConcreteStandardVaultImpl.FeeRecipientNotSet());
            require(
                managementFee_ <= ConcreteV2FeeParamsLib.MAX_MANAGEMENT_FEE,
                IConcreteStandardVaultImpl.ManagementFeeExceedsMaximum()
            );
        }

        $.managementFee = managementFee_;
        emit IConcreteStandardVaultImpl.ManagementFeeUpdated(managementFee_);
    }

    /// @dev Updates the management fee recipient
    /// @param recipient The new management fee recipient
    function updateManagementFeeRecipient(address recipient) external {
        require(recipient != address(0), IConcreteStandardVaultImpl.InvalidFeeRecipient());

        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        $.managementFeeRecipient = recipient;
        emit IConcreteStandardVaultImpl.ManagementFeeRecipientUpdated(recipient);
    }

    function updatePerformanceFee(uint16 performanceFee_) public {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        if (performanceFee_ > 0) {
            require($.performanceFeeRecipient != address(0), IConcreteStandardVaultImpl.FeeRecipientNotSet());
            require(
                performanceFee_ <= ConcreteV2FeeParamsLib.MAX_PERFORMANCE_FEE,
                IConcreteStandardVaultImpl.PerformanceFeeExceedsMaximum()
            );
        }

        $.performanceFee = performanceFee_;
        emit IConcreteStandardVaultImpl.PerformanceFeeUpdated(performanceFee_);
    }

    function updatePerformanceFeeRecipient(address recipient) external {
        require(recipient != address(0), IConcreteStandardVaultImpl.InvalidFeeRecipient());

        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();
        $.performanceFeeRecipient = recipient;
        emit IConcreteStandardVaultImpl.PerformanceFeeRecipientUpdated(recipient);
    }

    /**
     * @dev Sets the deposit limits for the vault.
     * @param minTxDepositAmount The minimum deposit amount per transaction.
     * @param maxGlobalDepositAmount The maximum global deposit amount (applies to total assets across all users).
     */
    function setDepositLimits(uint256 minTxDepositAmount, uint256 maxGlobalDepositAmount) public {
        require(maxGlobalDepositAmount >= minTxDepositAmount, IConcreteStandardVaultImpl.InvalidDepositLimits());

        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        $.maxGlobalDepositAmount = maxGlobalDepositAmount;
        $.minTxDepositAmount = minTxDepositAmount;
        emit IConcreteStandardVaultImpl.DepositLimitsUpdated(maxGlobalDepositAmount, minTxDepositAmount);
    }

    function setWithdrawLimits(uint256 minTxWithdrawAmount, uint256 maxTxWithdrawAmount) public {
        require(maxTxWithdrawAmount >= minTxWithdrawAmount, IConcreteStandardVaultImpl.InvalidWithdrawLimits());

        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        $.maxTxWithdrawAmount = maxTxWithdrawAmount;
        $.minTxWithdrawAmount = minTxWithdrawAmount;
        emit IConcreteStandardVaultImpl.WithdrawLimitsUpdated(maxTxWithdrawAmount, minTxWithdrawAmount);
    }

    function configure(IConcreteStandardVaultImpl.VaultManagerConfig configType, bytes calldata data) external {
        if (configType == IConcreteStandardVaultImpl.VaultManagerConfig.ManagementFee) {
            updateManagementFee(abi.decode(data, (uint16)));
        } else if (configType == IConcreteStandardVaultImpl.VaultManagerConfig.PerformanceFee) {
            updatePerformanceFee(abi.decode(data, (uint16)));
        } else if (configType == IConcreteStandardVaultImpl.VaultManagerConfig.HurdleRateOracle) {
            setHurdleRateOracle(abi.decode(data, (IHurdleRateOracle)));
        } else if (configType == IConcreteStandardVaultImpl.VaultManagerConfig.DepositLimits) {
            (uint256 minTx, uint256 maxGlobal) = abi.decode(data, (uint256, uint256));
            setDepositLimits(minTx, maxGlobal);
        } else if (configType == IConcreteStandardVaultImpl.VaultManagerConfig.WithdrawLimits) {
            (uint256 minTx, uint256 maxTx) = abi.decode(data, (uint256, uint256));
            setWithdrawLimits(minTx, maxTx);
        } else if (configType == IConcreteStandardVaultImpl.VaultManagerConfig.CancellationEnabled) {
            setCancellationEnabled(abi.decode(data, (bool)));
        } else {
            revert IConcreteStandardVaultImpl.InvalidVaultManagerConfig();
        }
    }

    /// @dev Enables or disables user cancellation of pending withdrawal requests. Stored inverted
    ///      (`cancellationDisabled`) so the default (`false`) keeps cancellation enabled for
    ///      existing vaults after upgrade without any migration.
    function setCancellationEnabled(bool enabled) public {
        AVLib.fetch().cancellationDisabled = !enabled;
        emit IConcreteAsyncVaultImpl.CancellationEnabledSet(enabled);
    }

    function setHurdleRateOracle(IHurdleRateOracle oracle) public {
        SVLib.fetch().hurdleRateOracle = oracle;
        emit IConcreteStandardVaultImpl.HurdleRateOracleUpdated(address(oracle));
    }

    function setHooks(Hooks memory hooks) external {
        if (hooks.target != address(0) && IHook(hooks.target).VAULT() != address(this)) {
            revert IConcreteStandardVaultImpl.InvalidHookVault(hooks.target);
        }
        SVLib.fetch().hooks = hooks;
        emit IConcreteStandardVaultImpl.HooksSet(hooks);
    }

    function addStrategy(address strategy, address asset) external {
        require(IStrategyTemplate(strategy).asset() == asset, IConcreteStandardVaultImpl.InvalidStrategyAsset());
        require(
            IStrategyTemplate(strategy).getVault() == address(this), IConcreteStandardVaultImpl.InvalidStrategyVault()
        );

        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        require($.strategies.add(strategy), IConcreteStandardVaultImpl.StrategyAlreadyAdded());
        $.strategyData[strategy] = IConcreteStandardVaultImpl.StrategyData({
            status: IConcreteStandardVaultImpl.StrategyStatus.Active, allocated: 0
        });

        emit IConcreteStandardVaultImpl.StrategyAdded(strategy);
    }

    function removeStrategy(address strategy) external {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        IConcreteStandardVaultImpl.StrategyData memory strategyDataCached = $.strategyData[strategy];

        // A strategy can only be removed once its position is settled and it is out of the
        // deallocation order. A Halted strategy that still holds an allocation must first be
        // reconciled via reconcileHaltedStrategy; otherwise dropping its `allocated` here would
        // inflate the derived floating amount (phantom funds).
        require(
            strategyDataCached.allocated == 0 && _strategyNotInDeallocationOrder(strategy),
            IConcreteStandardVaultImpl.StrategyHasAllocation()
        );
        require($.strategies.remove(strategy), IConcreteStandardVaultImpl.StrategyDoesNotExist());

        delete $.strategyData[strategy];
        _removeStrategyFromDeallocationOrder(strategy);

        emit IConcreteStandardVaultImpl.StrategyRemoved(strategy);
    }

    /**
     * @dev Reconciles the frozen allocation of a Halted strategy and removes it.
     *      - When `toStrategy == address(0)`: the position is written off as a realized loss
     *        (`cachedTotalAssets` drops by `allocated`, socialized across shareholders).
     *      - Otherwise: the allocation is migrated onto an Active `toStrategy`, preserving
     *        `cachedTotalAssets` and the aggregate allocation; the next yield accrual on the
     *        destination reconciles any real shortfall.
     *      Either branch keeps the derived floating amount exact.
     */
    function reconcileHaltedStrategy(address fromStrategy, address toStrategy) external {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        require($.strategies.contains(fromStrategy), IConcreteStandardVaultImpl.StrategyDoesNotExist());

        IConcreteStandardVaultImpl.StrategyData memory fromDataCached = $.strategyData[fromStrategy];
        require(
            fromDataCached.status == IConcreteStandardVaultImpl.StrategyStatus.Halted,
            IConcreteStandardVaultImpl.StrategyNotHalted()
        );
        require(fromDataCached.allocated > 0, IConcreteStandardVaultImpl.StrategyHasNoAllocation());

        if (toStrategy == address(0)) {
            // Write the frozen position off as a realized loss (socialized across shareholders).
            CachedVaultStateLib.fetch().cachedTotalAssets -= fromDataCached.allocated;
            emit IConcreteStandardVaultImpl.StrategyLossRealized(fromStrategy, fromDataCached.allocated);
        } else {
            // Move the accounting position onto the trusted Active strategy (checked uint120 add).
            require($.strategies.contains(toStrategy), IConcreteStandardVaultImpl.StrategyDoesNotExist());
            require(
                $.strategyData[toStrategy].status == IConcreteStandardVaultImpl.StrategyStatus.Active,
                IConcreteStandardVaultImpl.StrategyIsHalted()
            );
            $.strategyData[toStrategy].allocated += fromDataCached.allocated;
            emit IConcreteStandardVaultImpl.StrategyAllocationMigrated(
                fromStrategy, toStrategy, fromDataCached.allocated
            );
        }

        $.strategies.remove(fromStrategy);
        delete $.strategyData[fromStrategy];
        _removeStrategyFromDeallocationOrder(fromStrategy);

        emit IConcreteStandardVaultImpl.StrategyRemoved(fromStrategy);
    }

    /**
     * @dev Removes all instances of a strategy from the deallocation order array.
     *      Preserves the relative order of remaining strategies.
     *      Handles duplicated entries (e.g. from setDeallocationOrder with duplicates).
     * @param strategy The strategy address to remove from deallocation order.
     */
    function _removeStrategyFromDeallocationOrder(address strategy) internal {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        address[] storage deallocationOrder = $.deallocationOrder;
        uint256 i;
        while (i < deallocationOrder.length) {
            if (deallocationOrder[i] == strategy) {
                // Shift elements to preserve relative order of remaining strategies
                for (uint256 j = i; j < deallocationOrder.length - 1; ++j) {
                    deallocationOrder[j] = deallocationOrder[j + 1];
                }
                deallocationOrder.pop();
                emit IConcreteStandardVaultImpl.DeallocationOrderUpdated();
                // Do not increment i - next element is now at position i
            } else {
                ++i;
            }
        }
    }

    function toggleStrategyStatus(address strategy) external {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        require($.strategies.contains(strategy), IConcreteStandardVaultImpl.StrategyDoesNotExist());

        IConcreteStandardVaultImpl.StrategyStatus currentStatus = $.strategyData[strategy].status;

        if (currentStatus == IConcreteStandardVaultImpl.StrategyStatus.Active) {
            $.strategyData[strategy].status = IConcreteStandardVaultImpl.StrategyStatus.Halted;
        } else {
            $.strategyData[strategy].status = IConcreteStandardVaultImpl.StrategyStatus.Active;
        }

        emit IConcreteStandardVaultImpl.StrategyStatusToggled(strategy);
    }

    /**
     * @dev Internal function to check if a strategy is not in the deallocation order.
     * @param strategy The strategy address to check.
     * @return True if the strategy is not in the deallocation order, false otherwise.
     */
    function _strategyNotInDeallocationOrder(address strategy) internal view returns (bool) {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        address[] memory deallocationOrder = $.deallocationOrder;
        uint256 deallocationOrderLength = deallocationOrder.length;
        for (uint256 i = 0; i < deallocationOrderLength; i++) {
            if (deallocationOrder[i] == strategy) {
                return false;
            }
        }
        return true;
    }

    /**
     * @notice overwrites the deallocation order from strategies;
     */
    function setDeallocationOrder(address[] calldata order) external {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        delete $.deallocationOrder;

        uint256 orderLength = order.length;
        for (uint256 i = 0; i < orderLength; i++) {
            address strategy = order[i];
            require($.strategies.contains(strategy), IConcreteStandardVaultImpl.StrategyDoesNotExist());
            require(
                $.strategyData[strategy].status == IConcreteStandardVaultImpl.StrategyStatus.Active,
                IConcreteStandardVaultImpl.StrategyIsHalted()
            );
        }

        $.deallocationOrder = order;

        emit IConcreteStandardVaultImpl.DeallocationOrderUpdated();
    }

    /**
     * @notice Set the unwind cost cap for priority withdrawals
     * @dev Validates that the unwind cost cap does not exceed BASIS_POINTS
     * @param unwindCostCap_ The new unwind cost cap in basis points (10000 = 100%)
     */
    function setUnwindCostCap(uint16 unwindCostCap_) external {
        require(unwindCostCap_ <= AsyncVaultHelperLib.BASIS_POINTS, IConcreteAsyncVaultImpl.InvalidUnwindCostCap());
        AVLib.ConcreteAsyncVaultImplStorage storage $ = AVLib.fetch();
        $.unwindCostCapBP = unwindCostCap_;
    }

    // ── Multi-asset deposit vault ─────────────────────────────────────────────

    /**
     * @dev Multi-asset admin dispatcher. Runs in the vault's storage context via DELEGATECALL,
     *      mirroring {configure} for the base vault-manager config. A dispatcher keeps the vault
     *      runtime bytecode under EIP-170 (dedicated setters proved larger).
     */
    function configureMultiAsset(IMAV.MultiAssetVaultManagerConfig configType, bytes calldata data) external {
        if (configType == IMAV.MultiAssetVaultManagerConfig.AddWhitelistedAsset) {
            addWhitelistedAsset(abi.decode(data, (address)));
        } else if (configType == IMAV.MultiAssetVaultManagerConfig.SetPricer) {
            setMultiAssetPricer(abi.decode(data, (address)));
        } else if (configType == IMAV.MultiAssetVaultManagerConfig.SetMultiAssetStrategy) {
            setMultiAssetStrategy(abi.decode(data, (address)));
        } else {
            revert IMAV.InvalidMultiAssetConfig();
        }
    }

    /// @dev Whitelists a non-base deposit asset. The base `asset()` is implicitly accepted
    ///      (routed to the inherited ERC-4626 flow) and must not be whitelisted.
    function addWhitelistedAsset(address asset) public {
        require(asset != address(0), IConcreteAsyncVaultImpl.ZeroAddress());
        require(asset != IERC4626(address(this)).asset(), IMAV.CannotWhitelistBaseAsset());
        // The vault is its own ERC-20 share token; whitelisting it as a deposit asset must be blocked.
        require(asset != address(this), IMAV.CannotWhitelistShareToken());
        require(MASLib.fetch().whitelistedAssets.add(asset), IMAV.AssetAlreadyWhitelisted(asset));
        emit IMAV.WhitelistedAssetAdded(asset);
    }

    /// @dev Removes a non-base deposit asset from the whitelist. This only blocks new deposits;
    ///      any existing allocation originated from that asset stays fully accounted for.
    function removeWhitelistedAsset(address asset) public {
        require(MASLib.fetch().whitelistedAssets.remove(asset), IMAV.AssetNotWhitelisted(asset));
        emit IMAV.WhitelistedAssetRemoved(asset);
    }

    /// @dev Sets the asset pricer used to value non-base deposits in base units.
    function setMultiAssetPricer(address pricer) public {
        require(pricer != address(0), IMAV.InvalidPricer());
        MASLib.fetch().pricer = pricer;
        emit IMAV.MultiAssetPricerSet(pricer);
    }

    /// @dev Sets the single strategy that receives non-base deposits. The strategy must already
    ///      be a registered, Active strategy of the vault. Repointing does not require the previous
    ///      strategy to be drained: it stays tracked by the vault's standard accounting and only the
    ///      destination for future deposits changes.
    /// @dev This is not the only writer of `MASLib.strategy`. {StateSetterMASLib} keeps the pointer in
    ///      step with the registry lifecycle — clearing it when the designated strategy is removed and
    ///      moving it onto the successor when a halted one is reconciled. So `address(0)` is reachable
    ///      after configuration even though this setter rejects it; {MultiAssetVaultHelperLib} then
    ///      reverts `MultiAssetNotConfigured` until governance designates a new strategy here.
    function setMultiAssetStrategy(address strategy) public {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();
        require(
            $.strategies.contains(strategy)
                && $.strategyData[strategy].status == IConcreteStandardVaultImpl.StrategyStatus.Active,
            IMAV.InvalidMultiAssetStrategy(strategy)
        );
        MASLib.fetch().strategy = strategy;
        emit IMAV.MultiAssetStrategySet(strategy);
    }
}
