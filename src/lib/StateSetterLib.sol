// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ConcreteStandardVaultImplStorageLib as SVLib} from "./storage/ConcreteStandardVaultImplStorageLib.sol";
import {ConcreteAsyncVaultImplStorageLib as AVLib} from "./storage/ConcreteAsyncVaultImplStorageLib.sol";
import {EnumerableSet} from "@openzeppelin-contracts/utils/structs/EnumerableSet.sol";
import {IConcreteStandardVaultImpl} from "../interface/IConcreteStandardVaultImpl.sol";
import {IConcreteAsyncVaultImpl} from "../interface/IConcreteAsyncVaultImpl.sol";
import {ConcreteV2FeeParamsLib} from "./Constants.sol";
import {AsyncVaultHelperLib} from "./AsyncVaultHelperLib.sol";

library StateSetterLib {
    using EnumerableSet for EnumerableSet.AddressSet;

    function updateManagementFee(uint16 managementFee_) external {
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

    function updatePerformanceFee(uint16 performanceFee_) external {
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
    function setDepositLimits(uint256 minTxDepositAmount, uint256 maxGlobalDepositAmount) external {
        require(maxGlobalDepositAmount >= minTxDepositAmount, IConcreteStandardVaultImpl.InvalidDepositLimits());

        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        $.maxGlobalDepositAmount = maxGlobalDepositAmount;
        $.minTxDepositAmount = minTxDepositAmount;
        emit IConcreteStandardVaultImpl.DepositLimitsUpdated(maxGlobalDepositAmount, minTxDepositAmount);
    }

    function setWithdrawLimits(uint256 minTxWithdrawAmount, uint256 maxTxWithdrawAmount) external {
        require(maxTxWithdrawAmount >= minTxWithdrawAmount, IConcreteStandardVaultImpl.InvalidWithdrawLimits());

        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        $.maxTxWithdrawAmount = maxTxWithdrawAmount;
        $.minTxWithdrawAmount = minTxWithdrawAmount;
        emit IConcreteStandardVaultImpl.WithdrawLimitsUpdated(maxTxWithdrawAmount, minTxWithdrawAmount);
    }

    function addStrategy(address strategy) external {
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

        require(
            (strategyDataCached.allocated == 0 && _strategyNotInDeallocationOrder(strategy))
                || strategyDataCached.status == IConcreteStandardVaultImpl.StrategyStatus.Halted,
            IConcreteStandardVaultImpl.StrategyHasAllocation()
        );
        require($.strategies.remove(strategy), IConcreteStandardVaultImpl.StrategyDoesNotExist());

        delete $.strategyData[strategy];
        _removeStrategyFromDeallocationOrder(strategy);

        emit IConcreteStandardVaultImpl.StrategyRemoved(strategy);
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
}
