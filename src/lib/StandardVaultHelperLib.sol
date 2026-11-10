// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {ConcreteV2ConversionLib as ConversionLib} from "./Conversion.sol";
import {ConcreteStandardVaultImplStorageLib as SVLib} from "./storage/ConcreteStandardVaultImplStorageLib.sol";
import {
    ConcreteCachedVaultStateStorageLib as CachedVaultStateLib
} from "./storage/ConcreteCachedVaultStateStorageLib.sol";
import {YieldAccrualLib} from "./YieldAccrualLib.sol";
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
        public
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
    ) public pure returns (uint256) {
        uint256 maxDepositAmount = calcMaxDeposit(maxGlobalDepositLimit, minTxDepositAmount, totalAssets_);

        // Early return if no deposit is allowed
        if (maxDepositAmount == 0) {
            return 0;
        }

        // Floor the remaining capacity to shares, then ceil back the way {mint} does.
        // If that round-trip lands below `minTxDepositAmount`, no share amount is mintable
        // even though `maxDeposit` may still be non-zero.
        uint256 maxShares =
            ConversionLib.calcConvertToShares(maxDepositAmount, totalSupply_, totalAssets_, Math.Rounding.Floor, false);
        uint256 assetsNeeded =
            ConversionLib.calcConvertToAssets(maxShares, totalSupply_, totalAssets_, Math.Rounding.Ceil, false);
        return assetsNeeded >= minTxDepositAmount ? maxShares : 0;
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
    ) public pure returns (uint256) {
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
    ) public pure returns (uint256) {
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

    function previewDeposit(uint256 assets) public view returns (uint256) {
        (uint256 ta, uint256 ts) =
            YieldAccrualLib.previewAccrueYieldAndFees(CachedVaultStateLib.fetch().cachedTotalAssets);
        return ConversionLib.calcConvertToShares(assets, ts, ta, Math.Rounding.Floor, false);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        (uint256 ta, uint256 ts) =
            YieldAccrualLib.previewAccrueYieldAndFees(CachedVaultStateLib.fetch().cachedTotalAssets);
        return ConversionLib.calcConvertToAssets(shares, ts, ta, Math.Rounding.Ceil, false);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        (uint256 ta, uint256 ts) =
            YieldAccrualLib.previewAccrueYieldAndFees(CachedVaultStateLib.fetch().cachedTotalAssets);
        return ConversionLib.calcConvertToShares(assets, ts, ta, Math.Rounding.Ceil, false);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        (uint256 ta, uint256 ts) =
            YieldAccrualLib.previewAccrueYieldAndFees(CachedVaultStateLib.fetch().cachedTotalAssets);
        return ConversionLib.calcConvertToAssets(shares, ts, ta, Math.Rounding.Floor, false);
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

    /**
     * @dev Derived floating amount: legitimate assets physically held by the vault
     *      (idle + locked), excluding donations. Replaces the previously stored
     *      `floating` variable.
     *
     *      floating = cachedTotalAssets - SUM(strategy.allocated) + lockedAssets
     *
     *      This holds because `cachedTotalAssets` and the per-strategy `allocated`
     *      values always move together (deposits, allocations, yield accrual), so the
     *      difference is exactly the idle assets; donations never enter the computation.
     *
     *      The idle component is clamped at 0 to stay robust if accounting ever desyncs.
     *      Callers that must reject over-allocation (e.g. `allocate`) MUST use an explicit
     *      `cachedTotalAssets >= calcTotalAllocated()` check instead of this helper, since
     *      the clamp would otherwise hide the desync.
     * @param lockedAssets Assets reserved for already-burned withdrawal requests.
     * @return The derived floating amount (idle + lockedAssets).
     */
    function floatingAmount(uint256 lockedAssets) public view returns (uint256) {
        uint256 cachedTotalAssets = CachedVaultStateLib.fetch().cachedTotalAssets;
        uint256 totalAllocated = calcTotalAllocated();
        uint256 idle = cachedTotalAssets > totalAllocated ? cachedTotalAssets - totalAllocated : 0;
        return idle + lockedAssets;
    }
}
