// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {ConcreteV2ConversionLib as ConversionLib} from "./Conversion.sol";
import {ConcreteStandardVaultImplStorageLib as SVLib} from "./storage/ConcreteStandardVaultImplStorageLib.sol";
import {EnumerableSet} from "@openzeppelin-contracts/utils/structs/EnumerableSet.sol";

library StandardVaultHelperLib {
    using EnumerableSet for EnumerableSet.AddressSet;

    /**
     * @dev Calculates the maximum deposit amount based on deposit limits and current total assets.
     * @param maxGlobalDepositLimit The maximum global deposit limit configured for the vault (applies to total assets across all users).
     * @param minTxDepositAmount The minimum deposit amount configured for the vault.
     * @param totalAssets_ The current total assets (after yield accrual).
     * @return The maximum amount of assets that can be deposited, or 0 if deposits are disabled or limit reached.
     */
    function calcMaxDeposit(uint256 maxGlobalDepositLimit, uint256 minTxDepositAmount, uint256 totalAssets_)
        internal
        pure
        returns (uint256)
    {
        // If deposits are disabled, return 0
        if (maxGlobalDepositLimit == 0) {
            return 0;
        }

        // If limit already reached, return 0
        if (totalAssets_ >= maxGlobalDepositLimit) {
            return 0;
        }

        uint256 maxRemainingDepositAmount = maxGlobalDepositLimit - totalAssets_;
        // Calculate maximum available deposit amount
        return maxRemainingDepositAmount >= minTxDepositAmount ? maxRemainingDepositAmount : 0;
    }

    /**
     * @dev Calculates the maximum mint amount (in shares) based on deposit limits and current vault state.
     * @param maxGlobalDepositLimit The maximum global deposit limit configured for the vault (applies to total assets across all users).
     * @param minTxDepositAmount The minimum deposit amount configured for the vault.
     * @param totalAssets_ The current total assets (after yield accrual).
     * @param totalSupply_ The current total supply (after yield accrual).
     * @return The maximum amount of shares that can be minted, or 0 if deposits are disabled or limit reached.
     */
    function calcMaxMint(
        uint256 maxGlobalDepositLimit,
        uint256 minTxDepositAmount,
        uint256 totalAssets_,
        uint256 totalSupply_
    ) internal pure returns (uint256) {
        uint256 maxDepositAmount = calcMaxDeposit(maxGlobalDepositLimit, minTxDepositAmount, totalAssets_);

        // Early return if no deposit is allowed
        if (maxDepositAmount == 0) {
            return 0;
        }

        return
            ConversionLib.calcConvertToShares(maxDepositAmount, totalSupply_, totalAssets_, Math.Rounding.Floor, false);
    }

    /**
     * @dev Calculates the maximum withdraw amount (in assets) based on owner balance and withdraw limits.
     * @param ownerShares The amount of shares owned by the user.
     * @param maxTxWithdrawLimit The maximum withdraw limit configured for the vault.
     * @param minTxWithdrawAmount The minimum withdraw amount configured for the vault.
     * @param totalAssets_ The current total assets (after yield accrual).
     * @param totalSupply_ The current total supply (after yield accrual).
     * @return The maximum amount of assets that can be withdrawn, or 0 if withdrawals are disabled.
     */
    function calcMaxWithdraw(
        uint256 ownerShares,
        uint256 maxTxWithdrawLimit,
        uint256 minTxWithdrawAmount,
        uint256 totalAssets_,
        uint256 totalSupply_
    ) internal pure returns (uint256) {
        // If withdrawals are disabled, return 0
        if (maxTxWithdrawLimit == 0) {
            return 0;
        }

        // Calculate owner's share of assets
        uint256 ownerAssets =
            ConversionLib.calcConvertToAssets(ownerShares, totalSupply_, totalAssets_, Math.Rounding.Floor, false);

        uint256 maxWithdrawAmount = ownerAssets > maxTxWithdrawLimit ? maxTxWithdrawLimit : ownerAssets;
        // Return the minimum between owner's assets and the max withdraw limit
        return maxWithdrawAmount >= minTxWithdrawAmount ? maxWithdrawAmount : 0;
    }

    /**
     * @dev Calculates the maximum redeem amount (in shares) based on owner balance and withdraw limits.
     * @param ownerShares The amount of shares owned by the user.
     * @param maxTxWithdrawLimit The maximum withdraw limit configured for the vault.
     * @param minTxWithdrawAmount The minimum withdraw amount configured for the vault.
     * @param totalAssets_ The current total assets (after yield accrual).
     * @param totalSupply_ The current total supply (after yield accrual).
     * @return The maximum amount of shares that can be redeemed, or 0 if withdrawals are disabled.
     * @dev This function converts maxTxWithdrawLimit directly to shares (rounding down conservatively)
     *      to avoid double rounding errors that could prevent users from redeeming all their shares.
     */
    function calcMaxRedeem(
        uint256 ownerShares,
        uint256 maxTxWithdrawLimit,
        uint256 minTxWithdrawAmount,
        uint256 totalAssets_,
        uint256 totalSupply_
    ) internal pure returns (uint256) {
        // If withdrawals are disabled, return 0
        if (maxTxWithdrawLimit == 0) {
            return 0;
        }

        uint256 maxShares;

        if (maxTxWithdrawLimit == type(uint256).max) {
            maxShares = ownerShares;
        } else {
            // Convert maxTxWithdrawLimit directly to shares (rounding down conservatively)
            // This avoids double rounding: ownerShares -> ownerAssets -> maxShares
            // Instead: maxTxWithdrawLimit -> maxShares, then compare directly with ownerShares
            uint256 maxSharesFromLimit = ConversionLib.calcConvertToShares(
                maxTxWithdrawLimit, totalSupply_, totalAssets_, Math.Rounding.Floor, false
            );
            maxShares = ownerShares > maxSharesFromLimit ? maxSharesFromLimit : ownerShares;
        }

        uint256 resultingAssets =
            ConversionLib.calcConvertToAssets(maxShares, totalSupply_, totalAssets_, Math.Rounding.Floor, false);
        return resultingAssets >= minTxWithdrawAmount ? maxShares : 0;
    }

    /**
     * @dev Calculates the total amount of assets allocated across all strategies.
     * @return totalAllocated The sum of all strategy allocations.
     */
    function calcTotalAllocated() public view returns (uint256 totalAllocated) {
        SVLib.ConcreteStandardVaultImplStorage storage $ = SVLib.fetch();

        address[] memory strategies = $.strategies.values();
        uint256 strategiesLength = strategies.length;

        for (uint256 i; i < strategiesLength; ++i) {
            totalAllocated += $.strategyData[strategies[i]].allocated;
        }
    }
}
