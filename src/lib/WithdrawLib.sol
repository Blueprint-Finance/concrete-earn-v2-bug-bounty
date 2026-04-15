// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ConcreteStandardVaultImplStorageLib as SVLib} from "./storage/ConcreteStandardVaultImplStorageLib.sol";
import {IConcreteStandardVaultImpl} from "../interface/IConcreteStandardVaultImpl.sol";
import {IStrategyTemplate} from "../interface/IStrategyTemplate.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {EnumerableSet} from "@openzeppelin-contracts/utils/structs/EnumerableSet.sol";

/**
 * @title WithdrawLib
 * @notice Library for handling withdrawal operations from vault strategies.
 * @dev Contains public functions to reduce bytecode size of the main vault contract
 *      via delegatecall pattern. All functions access vault storage through EIP-7201
 *      namespaced storage.
 */
library WithdrawLib {
    using SafeCast for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    /**
     * @dev Executes withdrawals from strategies to fulfill a withdrawal request.
     * @dev This function iterates through strategies in deallocation order and withdraws
     *      assets until the requested amount is reached or all strategies are exhausted.
     * @param assetAddress The address of the underlying asset
     * @param requestedAssets The amount of assets requested to withdraw
     * @param lockedAssets The amount of assets that are locked and not available for withdrawal
     * @return totalWithdrawableAmount The total amount of assets that can be withdrawn
     */
    function executeWithdrawFromStrategies(address assetAddress, uint256 requestedAssets, uint256 lockedAssets)
        public
        returns (uint256 totalWithdrawableAmount)
    {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        uint256 floatingFunds = IERC20(assetAddress).balanceOf(address(this));
        totalWithdrawableAmount = floatingFunds >= lockedAssets ? floatingFunds - lockedAssets : 0;

        if (totalWithdrawableAmount < requestedAssets) {
            // Iterate directly over storage to avoid copying the entire array to memory
            // This is especially beneficial for small withdrawals that only need the first strategy
            uint256 strategiesCounter = $.deallocationOrder.length;

            for (uint256 i; i < strategiesCounter; ++i) {
                address strategy = $.deallocationOrder[i];
                require($.strategies.contains(strategy), IConcreteStandardVaultImpl.StaleDeallocationOrder(strategy));
                if ($.strategyData[strategy].status != IConcreteStandardVaultImpl.StrategyStatus.Active) continue;

                uint256 desiredAssets;
                unchecked {
                    desiredAssets = requestedAssets - totalWithdrawableAmount;
                }

                uint256 withdrawableAmountFromStrategy = IStrategyTemplate(strategy).maxWithdraw();
                uint256 withdrawAmount =
                    (withdrawableAmountFromStrategy >= desiredAssets) ? desiredAssets : withdrawableAmountFromStrategy;

                if (withdrawAmount > 0) {
                    uint256 actualWithdrawn = IStrategyTemplate(strategy).onWithdraw(withdrawAmount);
                    $.strategyData[strategy].allocated -= actualWithdrawn.toUint120();

                    totalWithdrawableAmount += actualWithdrawn;
                }

                if (totalWithdrawableAmount >= requestedAssets) break;
            }
        }
    }

    /**
     * @dev Simulates withdrawing an amount of assets from the vault without modifying state.
     * @dev This is a view function that calculates how much can be withdrawn by iterating
     *      through strategies, but does NOT update strategy allocated amounts.
     * @param assetAddress The address of the underlying asset
     * @param requestedAssets Amount of assets to withdraw
     * @param lockedAssets The amount of assets that are locked and not available for withdrawal
     * @return totalWithdrawableAmount Amount of assets that can be filled
     */
    function simulateWithdraw(address assetAddress, uint256 requestedAssets, uint256 lockedAssets)
        public
        view
        returns (uint256 totalWithdrawableAmount)
    {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        uint256 floatingFunds = IERC20(assetAddress).balanceOf(address(this));
        totalWithdrawableAmount = floatingFunds >= lockedAssets ? floatingFunds - lockedAssets : 0;

        if (totalWithdrawableAmount < requestedAssets) {
            // Iterate directly over storage to avoid copying the entire array to memory
            // This is especially beneficial for small withdrawals that only need the first strategy
            uint256 strategiesCounter = $.deallocationOrder.length;

            for (uint256 i; i < strategiesCounter; ++i) {
                address strategy = $.deallocationOrder[i];
                require($.strategies.contains(strategy), IConcreteStandardVaultImpl.StaleDeallocationOrder(strategy));
                if ($.strategyData[strategy].status != IConcreteStandardVaultImpl.StrategyStatus.Active) continue;

                uint256 desiredAssets;
                unchecked {
                    desiredAssets = requestedAssets - totalWithdrawableAmount;
                }

                uint256 withdrawableAmountFromStrategy = IStrategyTemplate(strategy).maxWithdraw();
                uint256 withdrawAmount =
                    (withdrawableAmountFromStrategy >= desiredAssets) ? desiredAssets : withdrawableAmountFromStrategy;

                totalWithdrawableAmount += withdrawAmount;

                if (totalWithdrawableAmount >= requestedAssets) break;
            }
        } else {
            totalWithdrawableAmount = requestedAssets;
        }
    }
}
