// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {WAD, RAY} from "./Constants.sol";

/// @title  PositionManagementHelperLib
/// @notice Pure math helpers for LTV-based position sizing.
///
/// @dev All prices are expressed in RAY (1 RAY = 1.0 price), all LTVs in WAD
///      (1e18 = 100%).  Token amounts are in native token units (collateral and
///      borrow tokens may have different decimals — the price already encodes
///      that conversion, see `_getCollateralPriceInBorrowTokensInRay`).
library PositionManagementHelperLib {
    using Math for uint256;

    /// @notice Maximum collateral `x` that can be withdrawn while keeping the
    ///         remaining position at or below `ltv`, given that `y` units of
    ///         debt will be repaid in the same transaction.
    ///
    /// @dev Derivation:
    ///        target LTV = (d − y) / ((c − x) · p)  =  ltv
    ///        ⟹  c − x  = (d − y) / (p · ltv)
    ///        ⟹      x  = c − (d − y) / (p · ltv)
    ///
    ///      In RAY / WAD scaled arithmetic:
    ///        x = c − mulDiv(mulDiv(d−y, RAY, p), WAD, ltv)
    ///
    ///      Bounds: [0, c].
    ///      • If p = 0                                    → x = 0 (safe default).
    ///      • If d ≤ y (debt fully covered by repayment) → x = c (withdraw all).
    ///      • If ltv = 0 (and d > y)                     → x = 0 (safe default).
    ///      • If the formula yields x < 0               → x = 0.
    ///
    /// @param c    Current collateral at the lender, in collateral token units.
    /// @param d    Current debt at the lender, in borrow token units.
    /// @param y    Debt repaid (or to be repaid in the same tx), in borrow token units.
    /// @param p    Price of one collateral token in borrow tokens, in RAY.
    /// @param ltv  Target LTV after the withdrawal, in WAD (1e18 = 100%).
    /// @return x   Collateral to withdraw, in collateral token units.
    function withdrawable(uint256 c, uint256 d, uint256 y, uint256 p, uint64 ltv) internal pure returns (uint256 x) {
        if (p == 0) return 0;
        if (d <= y) return c; // debt fully covered — withdraw all collateral
        if (ltv == 0) return 0; // remaining debt with no LTV allowance — nothing withdrawable

        uint256 remainingDebt = d - y;

        // requiredCollateral = (d − y) · RAY · WAD / (p · ltv)
        // Computed in two mulDiv steps to keep intermediates in uint256 range.
        // returned withdrawable amount is conservatively rounded down (never too high).
        uint256 requiredCollateral =
            remainingDebt.mulDiv(RAY, p, Math.Rounding.Ceil).mulDiv(WAD, uint256(ltv), Math.Rounding.Ceil);

        return requiredCollateral < c ? c - requiredCollateral : 0;
    }

    /// @notice LTV of the position *after* supplying `x` additional collateral,
    ///         given existing debt `d`.  This is the lowest LTV achievable by
    ///         supplying alone — any borrowing will push it higher.
    ///
    /// @dev Formula:
    ///        minLtv = d / ((c + x) · p)
    ///
    ///      In RAY / WAD scaled arithmetic:
    ///        collateralValue = (c + x).mulDiv(p, RAY)
    ///        minLtv          = d.mulDiv(WAD, collateralValue)
    ///
    ///      Returns type(uint256).max when collateral value is 0 (safe sentinel:
    ///      caller interprets this as "already above any target" → no borrow).
    ///
    /// @param d  Current debt, in borrow token units.
    /// @param c  Current collateral at the lender, in collateral token units.
    /// @param x  Additional collateral being supplied now, in collateral token units.
    /// @param p  Price of one collateral token in borrow tokens, in RAY.
    /// @return   Post-supply LTV in WAD (1e18 = 100%).
    function minLtv(uint256 d, uint256 c, uint256 x, uint256 p) internal pure returns (uint256) {
        if (p == 0) return type(uint256).max;
        uint256 collateralValue = (c + x).mulDiv(p, RAY);
        if (collateralValue == 0) return type(uint256).max;
        // returned LTV is conservatively rounded up (never too low).
        return d.mulDiv(WAD, collateralValue, Math.Rounding.Ceil);
    }

    /// @notice Borrow-token amount to borrow so the position reaches exactly `ltv`
    ///         after supplying `x` additional collateral.
    ///
    /// @dev Formula:
    ///        targetDebt   = (c + x) · p · ltv / (RAY · WAD)
    ///        borrowAmount = max(0, targetDebt − d)
    ///
    ///      Returns 0 when `ltv` is at or below the post-supply LTV (no borrowing
    ///      needed — caller should skip the borrow step).
    ///
    /// @param p    Price of one collateral token in borrow tokens, in RAY.
    /// @param ltv  Desired LTV after borrowing, in WAD (1e18 = 100%).
    /// @param c    Current collateral at the lender, in collateral token units.
    /// @param x    Additional collateral being supplied now, in collateral token units.
    /// @param d    Current debt at the lender, in borrow token units.
    /// @return     Amount to borrow, in borrow token units. 0 if no borrowing needed.
    function borrowAmountForTargetLtv(uint256 p, uint64 ltv, uint256 c, uint256 x, uint256 d)
        internal
        pure
        returns (uint256)
    {
        if (p == 0 || ltv == 0) return 0;
        uint256 targetDebt = (c + x).mulDiv(p, RAY).mulDiv(uint256(ltv), WAD);
        return targetDebt > d ? targetDebt - d : 0;
    }

    /// @notice Borrow-token amount to repay so that, after withdrawing `R` collateral,
    ///         the position lands exactly at `ltv`.
    ///
    /// @dev Formula:
    ///        targetDebt  = (c − R) · p · ltv / (RAY · WAD)
    ///        repayAmount = max(0, d − targetDebt)
    ///
    ///      Equivalently, solves for repay in:
    ///        ltv = (d − repay) / ((c − R) · p)
    ///
    ///      This is the scalar mirror of `borrowAmountForTargetLtv`: where that function
    ///      asks "how much to borrow to reach ltv after supplying?", this asks
    ///      "how much to repay to reach ltv after withdrawing R?".
    ///
    ///      Bounds:
    ///      • d = 0         → 0 (nothing to repay).
    ///      • R ≥ c         → d (withdraw all collateral → repay all debt).
    ///      • targetDebt ≥ d → 0 (already at or below ltv; no repayment needed).
    ///
    /// @param p    Price of one collateral token in borrow tokens, in RAY.
    /// @param ltv  Target LTV after repayment and withdrawal, in WAD (1e18 = 100%).
    /// @param c    Current collateral at the lender, in collateral token units.
    /// @param R    Collateral to be withdrawn, in collateral token units.
    /// @param d    Current debt at the lender, in borrow token units.
    /// @return     Borrow tokens to repay. 0 if no repayment needed.
    function repayAmountForTargetLtv(uint256 p, uint64 ltv, uint256 c, uint256 R, uint256 d)
        internal
        pure
        returns (uint256)
    {
        if (d == 0) return 0;
        if (R >= c) return d;
        uint256 targetDebt = (c - R).mulDiv(p, RAY).mulDiv(uint256(ltv), WAD);
        return d > targetDebt ? d - targetDebt : 0;
    }

    /// @notice Collateral to withdraw for a flash self-liquidation that repays exactly `y`
    ///         borrow tokens.
    ///
    /// @dev In the worst case the swap yields `pi*(1−f)/RAY` borrow tokens per collateral unit.
    ///      To obtain `y*(1+pr)` borrow tokens (flash repayment + premium):
    ///        x = y*(1+pr) / (pi*(1−f)/RAY)
    ///          = y * F * RAY / (WAD * pi)
    ///      where F_wad = WAD*(WAD+pr)/(WAD−f).
    ///
    ///      Result is ceiling-rounded so the withdrawn collateral is always sufficient.
    ///
    /// @param y   Borrow-token amount to repay (the flash amount), in borrow token units.
    /// @param pr  Flash premium in WAD (e.g. 9e14 = 0.09%).
    /// @param f   Max swap slippage in WAD (e.g. 5e16 = 5%).
    /// @param pi  Collateral price in borrow tokens, in RAY.
    /// @return    Collateral to withdraw, in collateral token units (ceiling).
    function flashWithdrawAmount(uint256 y, uint64 pr, uint64 f, uint256 pi) internal pure returns (uint256) {
        if (pi == 0) return 0;
        // F_wad = WAD * (WAD + pr) / (WAD − f) (ceiling rounding ensures F is never understated)
        uint256 F = WAD.mulDiv(WAD + uint256(pr), WAD - uint256(f), Math.Rounding.Ceil);
        // x = ceil(y * F * RAY / (WAD * pi))
        // Single mulDiv avoids intermediate floor truncation from a two-step y*F/WAD then *RAY/pi.
        return y.mulDiv(F * RAY, WAD * pi, Math.Rounding.Ceil);
    }

    /// @notice Collateral to withdraw for a flash self-liquidation that lands exactly at `ltv`.
    ///
    /// @dev Simultaneously solves:
    ///        ltv = (d − y) / ((c − x) · pi/RAY)    [post-liq LTV equation]
    ///        y   = x · pi/RAY · WAD/F_wad            [x → y via cost factor F]
    ///
    ///      Substituting y(x) and rearranging:
    ///        numerator   = d·RAY/pi − ltv·c/WAD    (collateral units; > 0 when LTV > target)
    ///        denominator = WAD²/F_wad − ltv/WAD    (WAD units;        > 0 when F < WAD/ltv)
    ///        x           = numerator · WAD / denominator   (ceiling)
    ///
    ///      Caller recovers the flash amount via: y = x.mulDiv(pi, RAY).mulDiv(WAD, F_wad).
    ///
    ///      Returns 0 when the position is already at or below `ltv`.
    ///      Returns type(uint256).max when `ltv` is unreachable (cost factor too large).
    ///
    /// @param ltv Target post-liquidation LTV, in WAD (1e18 = 100%).
    /// @param pr  Flash premium in WAD.
    /// @param f   Max swap slippage in WAD.
    /// @param c   Current collateral at the lender, in collateral token units.
    /// @param d   Current debt at the lender, in borrow token units.
    /// @param pi  Collateral price in borrow tokens, in RAY.
    /// @return    Collateral to withdraw, in collateral token units (ceiling).
    function flashWithdrawAmountFromTargetLtv(uint64 ltv, uint64 pr, uint64 f, uint256 c, uint256 d, uint256 pi)
        internal
        pure
        returns (uint256)
    {
        if (pi == 0 || d == 0) return 0;

        // F_wad = WAD * (WAD + pr) / (WAD − f) (ceiling — consistent with flashWithdrawAmount)
        uint256 F = WAD.mulDiv(WAD + uint256(pr), WAD - uint256(f), Math.Rounding.Ceil);

        // d expressed in collateral units: d * RAY / pi  (ceiling)
        uint256 dInCollateral = d.mulDiv(RAY, pi, Math.Rounding.Ceil);
        // ltv * c in collateral units: c * ltv / WAD
        uint256 ltvTimesC = c.mulDiv(uint256(ltv), WAD);

        // Position is already at or below target — no liquidation needed.
        if (dInCollateral <= ltvTimesC) return 0;

        uint256 numerator = dInCollateral - ltvTimesC; // collateral units

        // 1/F in WAD = WAD² / F_wad
        uint256 oneOverF = WAD.mulDiv(WAD, F);
        // Denominator = 1/F − ltv  (WAD units).
        // If 1/F ≤ ltv the target is unreachable: flash + slippage cost exceeds the liquidation gain.
        if (oneOverF <= uint256(ltv)) return type(uint256).max;
        uint256 denominator = oneOverF - uint256(ltv); // WAD units

        return numerator.mulDiv(WAD, denominator, Math.Rounding.Ceil);
    }

    /// @notice Collateral to sell so a position lands at `ltv` when sale proceeds repay
    ///         debt at the oracle price (no flash premium, no slippage haircut).
    ///
    /// @dev Simultaneously solves:
    ///        ltv = (d − y) / ((c − x) · p/RAY)    [post-sell LTV; both sides shrink]
    ///        y   = x · p/RAY                       [sale at oracle price]
    ///
    ///      Substituting y(x):
    ///        x = (d · RAY/p − ltv · c/WAD) · WAD / (WAD − ltv)   (ceiling)
    ///
    ///      This is the zero-premium, zero-slippage specialisation of
    ///      `flashWithdrawAmountFromTargetLtv`. Using `repayAmountForTargetLtv` with
    ///      R = 0 is incorrect here: that formula holds collateral constant and
    ///      under-sizes the sale (e.g. 100c/80d at 1:1 targeting 50% would sell 30
    ///      and land at ~71% LTV; the correct sale is 60, landing at 50%).
    ///
    ///      Returns 0 when the position is already at or below `ltv`.
    ///      Returns type(uint256).max when `ltv >= WAD` and the position is
    ///      underwater (selling at par cannot reduce LTV to 100% or above).
    ///
    /// @param p    Price of one collateral token in borrow tokens, in RAY.
    /// @param ltv  Target post-sale LTV, in WAD (1e18 = 100%).
    /// @param c    Current collateral at the lender, in collateral token units.
    /// @param d    Current debt at the lender, in borrow token units.
    /// @return     Collateral to sell, in collateral token units (ceiling).
    function sellAmountForTargetLtv(uint256 p, uint64 ltv, uint256 c, uint256 d) internal pure returns (uint256) {
        return flashWithdrawAmountFromTargetLtv(ltv, 0, 0, c, d, p);
    }

    /// @notice Borrow-token amount that should be redeployed into the target vault
    ///         so the position stays at `ltv` after withdrawing `R` collateral and
    ///         repaying `y` debt.
    ///
    /// @dev Derivation:
    ///        target_debt = p · ltv · (c − R)   (in borrow tokens)
    ///        redeposit   = target_debt − (d − y)
    ///
    ///      In RAY / WAD scaled arithmetic:
    ///        target_debt = mulDiv(mulDiv(c−R, p, RAY), ltv, WAD)
    ///
    ///      Bounds: [0, ∞).
    ///      • If R ≥ c (all or more collateral withdrawn) → 0.
    ///      • If p = 0 or ltv = 0                         → 0.
    ///      • If target_debt ≤ remaining_debt             → 0 (no redeployment needed).
    ///
    /// @param p    Price of one collateral token in borrow tokens, in RAY.
    /// @param ltv  Target LTV, in WAD (1e18 = 100%).
    /// @param c    Current collateral at the lender, in collateral token units.
    /// @param R    requested principal amount.
    /// @param d    Current debt at the lender, in borrow token units.
    /// @param y    Debt repaid, in borrow token units.
    /// @return     Borrow tokens to redeposit into the target vault. 0 if none needed.
    function redepositAmount(uint256 p, uint64 ltv, uint256 c, uint256 R, uint256 d, uint256 y)
        internal
        pure
        returns (uint256)
    {
        if (p == 0 || ltv == 0 || R >= c) return 0;

        uint256 newCollateral = c - R;

        // targetDebt = (c − R) · p · ltv / (RAY · WAD)
        uint256 targetDebt = newCollateral.mulDiv(p, RAY).mulDiv(uint256(ltv), WAD);

        uint256 remainingDebt = d > y ? d - y : 0;

        return targetDebt > remainingDebt ? targetDebt - remainingDebt : 0;
    }
}
