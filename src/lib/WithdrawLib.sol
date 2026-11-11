// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ConcreteStandardVaultImplStorageLib as SVLib} from "./storage/ConcreteStandardVaultImplStorageLib.sol";
import {IConcreteStandardVaultImpl} from "../interface/IConcreteStandardVaultImpl.sol";
import {StandardVaultHelperLib} from "./StandardVaultHelperLib.sol";
import {IStrategyTemplate} from "../interface/IStrategyTemplate.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {ERC4626_OZ_5_2_0_Lib} from "./ERC4626Lib.sol";
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
    using SafeERC20 for IERC20;

    /**
     * @notice Sweeps donated tokens held by the vault to a recipient.
     * @dev For the underlying asset, only the surplus above the derived floating balance is swept.
     *      For any other token, the entire balance is swept.
     *      Reverts if `token` is the vault share token (`address(this)`): that balance backs the
     *      escrow for queued withdrawal requests and is never a donation.
     *      Emits nothing and transfers nothing if the sweepable amount is zero.
     * @param token The ERC-20 token to sweep.
     * @param recipient The address that will receive the swept tokens.
     * @param lockedAssets Assets reserved for already-burned withdrawal requests.
     */
    function sweepDonatedTokens(address token, address recipient, uint256 lockedAssets) public {
        require(recipient != address(0), IConcreteStandardVaultImpl.InvalidReceiver());
        // The vault is its own share token; its balance backs queued withdrawal escrow, so it is
        // never a donation and must not be sweepable.
        require(token != address(this), IConcreteStandardVaultImpl.CannotSweepShareToken());
        address underlyingAsset = ERC4626_OZ_5_2_0_Lib.asset();
        uint256 balance = IERC20(token).balanceOf(address(this));

        uint256 amount;
        if (token == underlyingAsset) {
            uint256 floating_ = StandardVaultHelperLib.floatingAmount(lockedAssets);
            amount = balance > floating_ ? balance - floating_ : 0;
        } else {
            amount = balance;
        }

        if (amount > 0) {
            IERC20(token).safeTransfer(recipient, amount);
            emit IConcreteStandardVaultImpl.DonationSwept(token, recipient, amount);
        }
    }

    /**
     * @dev Executes withdrawals from strategies to fulfill a withdrawal request.
     * @dev This function iterates through strategies in deallocation order and withdraws
     *      assets until the requested amount is reached or all strategies are exhausted.
     * @param requestedAssets The amount of assets requested to withdraw
     * @param lockedAssets The amount of assets that are locked and not available for withdrawal
     * @return totalWithdrawableAmount The total amount of assets that can be withdrawn
     */
    function executeWithdrawFromStrategies(uint256 requestedAssets, uint256 lockedAssets)
        public
        returns (uint256 totalWithdrawableAmount)
    {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        // Derived floating excludes donations; the per-strategy `allocated` decrements below
        // are reflected automatically on the next read, so no stored floating to maintain.
        uint256 floating_ = StandardVaultHelperLib.floatingAmount(lockedAssets);
        totalWithdrawableAmount = floating_ >= lockedAssets ? floating_ - lockedAssets : 0;

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
     * @param requestedAssets Amount of assets to withdraw
     * @param lockedAssets The amount of assets that are locked and not available for withdrawal
     * @return totalWithdrawableAmount Amount of assets that can be filled
     */
    function simulateWithdraw(uint256 requestedAssets, uint256 lockedAssets)
        public
        view
        returns (uint256 totalWithdrawableAmount)
    {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        uint256 floating_ = StandardVaultHelperLib.floatingAmount(lockedAssets);
        totalWithdrawableAmount = floating_ >= lockedAssets ? floating_ - lockedAssets : 0;

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

        // ERC4626 compliance: if available liquidity falls below minTxWithdrawAmount,
        // return 0 so maxWithdraw/maxRedeem never advertise an amount that withdraw/redeem would reject.
        if (totalWithdrawableAmount < $.minTxWithdrawAmount) {
            totalWithdrawableAmount = 0;
        }
    }
}
