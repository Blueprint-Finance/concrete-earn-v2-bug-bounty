// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

import {PositionManagementHelperLib as PMHLib} from "../../../src/periphery/lib/PositionManagementHelperLib.sol";
import {WAD, RAY} from "../../../src/periphery/lib/Constants.sol";

/// @title  PositionManagementHelperLibTest
/// @notice Unit tests for every function in PositionManagementHelperLib.
///
/// @dev Canonical test fixture (used throughout unless a test explicitly overrides):
///
///   Collateral : WETH  (18 decimals)
///   Debt       : USDT  (6 decimals)
///   Price      : 1 WETH = 2 000 USDT
///   Price RAY  : 2 000 * 1e6 * RAY / 1e18  =  2e18
///                (price of 1 wei of WETH expressed in micro-USDT, scaled by RAY)
///
///   With these numbers every amount stays human-readable:
///     10 WETH collateral  =  10e18
///     10 000 USDT debt    =  10_000e6       (50 % LTV)
///      5 000 USDT debt    =   5_000e6       (25 % LTV)
///
/// @dev Validation strategy: for every "forward" result we perform a reverse
///   cross-check that reconstructs the invariant the function is supposed to
///   satisfy (e.g. re-derive LTV from the returned amount).  This catches
///   logic errors without depending on hardcoded magic numbers.
///   Integer-division rounding is accommodated with a 2-unit tolerance.
contract PositionManagementHelperLibTest is Test {
    using Math for uint256;

    // ── Canonical fixture values ──────────────────────────────────────────────

    /// Price of 1 wei of WETH in micro-USDT, scaled by RAY.
    /// Derivation: 2000 USDT/WETH * 1e6 (USDT decimals) * RAY / 1e18 (WETH decimals) = 2e18
    uint256 internal constant PRICE = 2e18;

    uint256 internal constant WETH = 1e18; // 1 WETH in wei
    uint256 internal constant USDT = 1e6; // 1 USDT in micro-USDT

    uint64 internal constant LTV_25 = 0.25e18; // 25 %
    uint64 internal constant LTV_50 = 0.5e18; // 50 %
    uint64 internal constant LTV_75 = 0.75e18; // 75 %

    // Rounding tolerance: 2 micro-USDT (smallest borrow unit)
    uint256 internal constant ROUNDING_TOL = 2;

    // ── Internal helper ───────────────────────────────────────────────────────

    /// @dev Converts collateral (WETH wei) to borrow token value (micro-USDT) using PRICE.
    function _collateralValue(uint256 collateralWei) internal pure returns (uint256) {
        return collateralWei.mulDiv(PRICE, RAY);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 1. withdrawable
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev 10 WETH collateral, 10 000 USDT debt (50 % LTV), no repayment.
    ///      Target LTV = 50 % → the position is already at target → x = 0.
    function testWithdrawable_zeroWhenAlreadyAtTargetLtv() public pure {
        uint256 c = 10 * WETH;
        uint256 d = 10_000 * USDT;
        uint256 y = 0;
        uint64 ltv = LTV_50;

        uint256 x = PMHLib.withdrawable(c, d, y, PRICE, ltv);

        assertEq(x, 0, "no collateral withdrawable when already at targetLtv");
    }

    /// @dev 10 WETH collateral, 5 000 USDT debt (25 % LTV), no repayment.
    ///      Target LTV = 50 % → position is BELOW target → can withdraw some collateral.
    ///      Expected: x = 10 - 5000/( 0.5 * 2000 ) = 10 - 5 = 5 WETH.
    ///      Reverse check: (d − y) / ((c − x) * PRICE / RAY) == ltv.
    function testWithdrawable_normalCase() public pure {
        uint256 c = 10 * WETH;
        uint256 d = 5_000 * USDT;
        uint256 y = 0;
        uint64 ltv = LTV_50;

        uint256 x = PMHLib.withdrawable(c, d, y, PRICE, ltv);

        // Hardcoded sanity: withdrawable = 5 WETH
        assertEq(x, 5 * WETH, "expected 5 WETH withdrawable");

        // Reverse: post-withdrawal LTV must equal targetLtv
        uint256 remainingCollateralValue = _collateralValue(c - x);
        uint256 derivedLtv = (d - y).mulDiv(WAD, remainingCollateralValue);
        assertApproxEqAbs(derivedLtv, ltv, ROUNDING_TOL, "reverse LTV check failed");
    }

    /// @dev Same setup but with partial repayment (2 000 USDT) alongside withdrawal.
    ///      After repaying 2 000 USDT residual debt = 3 000 USDT.
    ///      At 50 % LTV we need 3 000 / 0.5 / 2 000 = 3 WETH remaining → x = 7 WETH.
    function testWithdrawable_withPartialRepayment() public pure {
        uint256 c = 10 * WETH;
        uint256 d = 5_000 * USDT;
        uint256 y = 2_000 * USDT;
        uint64 ltv = LTV_50;

        uint256 x = PMHLib.withdrawable(c, d, y, PRICE, ltv);

        assertEq(x, 7 * WETH, "expected 7 WETH withdrawable with 2 000 USDT repayment");

        uint256 remainingCollateralValue = _collateralValue(c - x);
        uint256 derivedLtv = (d - y).mulDiv(WAD, remainingCollateralValue);
        assertApproxEqAbs(derivedLtv, ltv, ROUNDING_TOL, "reverse LTV check failed with repayment");
    }

    /// @dev When repayment >= debt, the entire debt is covered → withdraw all collateral.
    function testWithdrawable_fullRepaymentReturnsAllCollateral() public pure {
        uint256 c = 10 * WETH;
        uint256 d = 5_000 * USDT;
        uint256 y = 5_000 * USDT; // repay = debt

        uint256 x = PMHLib.withdrawable(c, d, y, PRICE, LTV_50);

        assertEq(x, c, "full repayment should allow withdrawing all collateral");
    }

    /// @dev When price is zero, withdraw nothing (safe default).
    function testWithdrawable_zeroPrice_returnsZero() public pure {
        assertEq(PMHLib.withdrawable(10 * WETH, 5_000 * USDT, 0, 0, LTV_50), 0, "zero price should return 0");
    }

    /// @dev When targetLtv is zero but debt remains, withdraw nothing (safe default).
    function testWithdrawable_zeroLtv_returnsZero() public pure {
        assertEq(PMHLib.withdrawable(10 * WETH, 5_000 * USDT, 0, PRICE, 0), 0, "zero ltv should return 0");
    }

    /// @dev When ltv is zero but debt is fully repaid on-chain (d == 0), all collateral
    ///      must be withdrawable. This is the _retract() atomic unwind case where
    ///      maxPermissibleLtv = 0 and the repayment has already settled before the
    ///      withdrawable check runs.
    function testWithdrawable_zeroLtv_zeroDebt_returnsAllCollateral() public pure {
        uint256 c = 10 * WETH;
        uint256 x = PMHLib.withdrawable(c, 0, 0, PRICE, 0);
        assertEq(x, c, "zero debt with zero ltv should allow withdrawing all collateral");
    }

    /// @dev When required collateral exceeds current collateral, return 0 (can't go negative).
    function testWithdrawable_insufficientCollateral_returnsZero() public pure {
        // 5 WETH collateral, 8 000 USDT debt → LTV = 80 %. Target = 50 %.
        // Required collateral = 8 000 / (0.5 * 2 000) = 8 WETH > 5 WETH → x = 0.
        uint256 x = PMHLib.withdrawable(5 * WETH, 8_000 * USDT, 0, PRICE, LTV_50);
        assertEq(x, 0, "should return 0 when debt requires more collateral than available");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 2. minLtv
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev 10 WETH collateral, 0 additional supply, 5 000 USDT debt.
    ///      minLtv = 5 000 / (10 * 2 000) = 25 %.
    function testMinLtv_normalCase() public pure {
        uint256 result = PMHLib.minLtv(5_000 * USDT, 10 * WETH, 0, PRICE);

        assertEq(result, LTV_25, "minLtv should be 25%");
    }

    /// @dev Supplying additional collateral dilutes LTV.
    ///      10 + 10 = 20 WETH, 5 000 USDT debt → minLtv = 5 000 / (20 * 2 000) = 12.5 %.
    function testMinLtv_withAdditionalSupply() public pure {
        uint256 result = PMHLib.minLtv(5_000 * USDT, 10 * WETH, 10 * WETH, PRICE);

        assertEq(result, 0.125e18, "minLtv should be 12.5% after doubling collateral");
    }

    /// @dev Zero debt → minLtv = 0.
    function testMinLtv_zeroDebt_returnsZero() public pure {
        assertEq(PMHLib.minLtv(0, 10 * WETH, 0, PRICE), 0, "zero debt should give zero LTV");
    }

    /// @dev Zero price → sentinel max (no borrowing capacity).
    function testMinLtv_zeroPrice_returnsMaxUint() public pure {
        assertEq(PMHLib.minLtv(5_000 * USDT, 10 * WETH, 0, 0), type(uint256).max, "zero price should return max");
    }

    /// @dev Zero collateral and zero additional supply → sentinel max.
    function testMinLtv_zeroCollateral_returnsMaxUint() public pure {
        assertEq(PMHLib.minLtv(5_000 * USDT, 0, 0, PRICE), type(uint256).max, "zero collateral should return max");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 3. borrowAmountForTargetLtv
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Fresh position: 10 WETH, no existing debt, target 50 % LTV.
    ///      Expected borrow = 10 * 2 000 * 0.5 = 10 000 USDT.
    ///      Reverse: (d + borrow) / ((c + x) * PRICE / RAY) == ltv.
    function testBorrowAmountForTargetLtv_freshPosition() public pure {
        uint256 c = 0;
        uint256 x = 10 * WETH;
        uint256 d = 0;
        uint64 ltv = LTV_50;

        uint256 borrow = PMHLib.borrowAmountForTargetLtv(PRICE, ltv, c, x, d);

        assertEq(borrow, 10_000 * USDT, "expected 10 000 USDT borrow for fresh 10 WETH at 50%");

        // Reverse: new LTV should equal target
        uint256 collateralValue = _collateralValue(c + x);
        uint256 derivedLtv = (d + borrow).mulDiv(WAD, collateralValue);
        assertApproxEqAbs(derivedLtv, ltv, ROUNDING_TOL, "reverse LTV check failed");
    }

    /// @dev Existing position at 25 % LTV, top-up to 50 %.
    ///      10 WETH, 5 000 USDT debt, supply 0 more, target 50 %.
    ///      Additional borrow = 10 * 2 000 * 0.5 − 5 000 = 5 000 USDT.
    function testBorrowAmountForTargetLtv_topUpExistingPosition() public pure {
        uint256 c = 10 * WETH;
        uint256 x = 0;
        uint256 d = 5_000 * USDT;
        uint64 ltv = LTV_50;

        uint256 borrow = PMHLib.borrowAmountForTargetLtv(PRICE, ltv, c, x, d);

        assertEq(borrow, 5_000 * USDT, "expected 5 000 USDT additional borrow");

        uint256 collateralValue = _collateralValue(c + x);
        uint256 derivedLtv = (d + borrow).mulDiv(WAD, collateralValue);
        assertApproxEqAbs(derivedLtv, ltv, ROUNDING_TOL, "reverse LTV check failed for top-up");
    }

    /// @dev Supply and top-up simultaneously: add 5 WETH on top of existing 10 WETH,
    ///      existing debt 5 000 USDT, target 50 %.
    ///      Target debt = (10 + 5) * 2 000 * 0.5 = 15 000 USDT → borrow = 10 000 USDT.
    function testBorrowAmountForTargetLtv_supplyAndBorrow() public pure {
        uint256 c = 10 * WETH;
        uint256 x = 5 * WETH;
        uint256 d = 5_000 * USDT;
        uint64 ltv = LTV_50;

        uint256 borrow = PMHLib.borrowAmountForTargetLtv(PRICE, ltv, c, x, d);

        assertEq(borrow, 10_000 * USDT, "expected 10 000 USDT additional borrow after supplying 5 WETH");

        uint256 collateralValue = _collateralValue(c + x);
        uint256 derivedLtv = (d + borrow).mulDiv(WAD, collateralValue);
        assertApproxEqAbs(derivedLtv, ltv, ROUNDING_TOL, "reverse LTV check failed");
    }

    /// @dev Already above target LTV → no borrowing needed.
    ///      10 WETH, 10 000 USDT debt (50 % LTV), target 25 % → borrow = 0.
    function testBorrowAmountForTargetLtv_alreadyAboveTarget_returnsZero() public pure {
        uint256 borrow = PMHLib.borrowAmountForTargetLtv(PRICE, LTV_25, 10 * WETH, 0, 10_000 * USDT);
        assertEq(borrow, 0, "should not borrow when already above targetLtv");
    }

    /// @dev Zero price → 0.
    function testBorrowAmountForTargetLtv_zeroPrice_returnsZero() public pure {
        assertEq(PMHLib.borrowAmountForTargetLtv(0, LTV_50, 10 * WETH, 0, 0), 0, "zero price should return 0");
    }

    /// @dev Zero ltv → 0.
    function testBorrowAmountForTargetLtv_zeroLtv_returnsZero() public pure {
        assertEq(PMHLib.borrowAmountForTargetLtv(PRICE, 0, 10 * WETH, 0, 0), 0, "zero ltv should return 0");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 4. repayAmountForTargetLtv
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev 10 WETH collateral, 10 000 USDT debt (50 % LTV), withdraw 5 WETH, target 25 %.
    ///      After withdrawing 5 WETH: 5 WETH remains.
    ///      Target debt at 25 % on 5 WETH = 5 * 2 000 * 0.25 = 2 500 USDT.
    ///      Repay = 10 000 − 2 500 = 7 500 USDT.
    ///      Reverse: (d − repay) / ((c − R) * PRICE / RAY) == ltv.
    function testRepayAmountForTargetLtv_normalCase() public pure {
        uint256 c = 10 * WETH;
        uint256 d = 10_000 * USDT;
        uint256 R = 5 * WETH;
        uint64 ltv = LTV_25;

        uint256 repay = PMHLib.repayAmountForTargetLtv(PRICE, ltv, c, R, d);

        assertEq(repay, 7_500 * USDT, "expected 7 500 USDT repayment");

        uint256 remainingCollateralValue = _collateralValue(c - R);
        uint256 derivedLtv = (d - repay).mulDiv(WAD, remainingCollateralValue);
        assertApproxEqAbs(derivedLtv, ltv, ROUNDING_TOL, "reverse LTV check failed");
    }

    /// @dev No withdrawal (R = 0), reduce from 50 % to 25 % LTV by repaying.
    ///      Target debt = 10 * 2 000 * 0.25 = 5 000 USDT → repay = 5 000 USDT.
    function testRepayAmountForTargetLtv_repayOnlyNoWithdrawal() public pure {
        uint256 c = 10 * WETH;
        uint256 d = 10_000 * USDT;
        uint256 R = 0;
        uint64 ltv = LTV_25;

        uint256 repay = PMHLib.repayAmountForTargetLtv(PRICE, ltv, c, R, d);

        assertEq(repay, 5_000 * USDT, "expected 5 000 USDT repay to reach 25% LTV");

        uint256 remainingCollateralValue = _collateralValue(c - R);
        uint256 derivedLtv = (d - repay).mulDiv(WAD, remainingCollateralValue);
        assertApproxEqAbs(derivedLtv, ltv, ROUNDING_TOL, "reverse LTV check failed");
    }

    /// @dev Withdrawing all collateral (R >= c) → repay entire debt.
    function testRepayAmountForTargetLtv_fullWithdrawal_repaysAllDebt() public pure {
        uint256 d = 10_000 * USDT;
        uint256 repay = PMHLib.repayAmountForTargetLtv(PRICE, LTV_50, 10 * WETH, 10 * WETH, d);
        assertEq(repay, d, "full withdrawal should require repaying all debt");
    }

    /// @dev Zero debt → nothing to repay.
    function testRepayAmountForTargetLtv_zeroDebt_returnsZero() public pure {
        assertEq(PMHLib.repayAmountForTargetLtv(PRICE, LTV_50, 10 * WETH, 5 * WETH, 0), 0, "zero debt returns 0");
    }

    /// @dev Already below target LTV after withdrawal → no repayment needed.
    ///      10 WETH, 1 000 USDT debt (5 % LTV), withdraw 5 WETH.
    ///      After withdrawal: 5 WETH, LTV = 1 000 / (5 * 2 000) = 10 % < 50 % target → repay = 0.
    function testRepayAmountForTargetLtv_alreadyBelowTarget_returnsZero() public pure {
        uint256 repay = PMHLib.repayAmountForTargetLtv(PRICE, LTV_50, 10 * WETH, 5 * WETH, 1_000 * USDT);
        assertEq(repay, 0, "no repayment needed when already below target LTV");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 5. flashWithdrawAmount
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Flash repay 10 000 USDT, 0.1 % premium, 1 % slippage, price = 2 000 USDT/WETH.
    ///      F = WAD * (WAD + pr) / (WAD − f)
    ///        = 1e18 * (1e18 + 1e15) / (1e18 − 1e16)
    ///        ≈ 1.011... e18
    ///      x = y * F / WAD * RAY / pi  (ceiling)
    ///        ≈ 10 000 * 1.011 / 2 000 ≈ 5.057 WETH → slightly above 5 WETH.
    ///      Reverse: x * pi / RAY * (WAD − f) / WAD >= y * (WAD + pr) / WAD.
    ///      Tolerance of 1: the reverse check itself applies floor division so can drop 1 unit.
    function testFlashWithdrawAmount_normalCase() public pure {
        uint256 y = 10_000 * USDT; // flash amount to repay
        uint64 pr = 0.001e18; // 0.1% flash premium
        uint64 f = 0.01e18; // 1% slippage

        uint256 x = PMHLib.flashWithdrawAmount(y, pr, f, PRICE);

        assertGt(x, 0, "withdraw amount should be non-zero");

        // Reverse: collateral sold at worst price (PRICE * (1-f)) must cover y * (1 + pr).
        // Tolerance of 1: both the F computation and this reverse check apply floor division,
        // so the check can land 1 micro-USDT below totalOwed even when x is correct.
        uint256 proceedsAtWorstPrice = x.mulDiv(PRICE, RAY).mulDiv(WAD - uint256(f), WAD);
        uint256 totalOwed = y.mulDiv(WAD + uint256(pr), WAD);
        assertApproxEqAbs(
            proceedsAtWorstPrice, totalOwed, 1, "collateral proceeds must cover flash repayment + premium"
        );
    }

    /// @dev Zero flash amount → zero collateral to withdraw.
    function testFlashWithdrawAmount_zeroAmount_returnsZero() public pure {
        assertEq(PMHLib.flashWithdrawAmount(0, 0.001e18, 0.01e18, PRICE), 0, "zero flash amount returns 0");
    }

    /// @dev Zero price → zero (no valid conversion).
    function testFlashWithdrawAmount_zeroPrice_returnsZero() public pure {
        assertEq(PMHLib.flashWithdrawAmount(10_000 * USDT, 0.001e18, 0.01e18, 0), 0, "zero price returns 0");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 6. flashWithdrawAmountFromTargetLtv
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev 10 WETH collateral, 10 000 USDT debt (50 % LTV), target 25 % LTV.
    ///      Flash liquidate to bring LTV from 50 % → 25 %.
    ///      Reverse: derive y from x, then verify post-liq LTV.
    ///      The reverse LTV uses a larger tolerance (1e9) because the derivation chains
    ///      three mulDiv operations, accumulating ~1e8 WAD units of rounding error.
    function testFlashWithdrawAmountFromTargetLtv_normalCase() public pure {
        uint256 c = 10 * WETH;
        uint256 d = 10_000 * USDT;
        uint64 ltv = LTV_25;
        uint64 pr = 0.001e18; // 0.1% flash premium
        uint64 f = 0.01e18; // 1% slippage

        uint256 x = PMHLib.flashWithdrawAmountFromTargetLtv(ltv, pr, f, c, d, PRICE);

        assertGt(x, 0, "should withdraw some collateral");
        assertLt(x, c, "should not withdraw more than total collateral");

        // Derive flash repayment y from x using the same F factor.
        uint256 F = WAD.mulDiv(WAD + uint256(pr), WAD - uint256(f));
        uint256 y = x.mulDiv(PRICE, RAY).mulDiv(WAD, F);

        // Post-liquidation LTV = (d − y) / ((c − x) * PRICE / RAY).
        // Tolerance 1e9: three chained mulDiv steps accumulate ~1e8 WAD units of rounding
        // error, which is negligible (~4e-9 relative) but exceeds the 2-unit default.
        uint256 remainingCollateralValue = _collateralValue(c - x);
        uint256 postLiqLtv = (d - y).mulDiv(WAD, remainingCollateralValue);
        assertApproxEqAbs(postLiqLtv, ltv, 1e9, "post-liquidation LTV should match target");
    }

    /// @dev Already at or below target LTV → returns 0 (no liquidation needed).
    ///      10 WETH, 2 000 USDT debt (10 % LTV), target 25 % → x = 0.
    function testFlashWithdrawAmountFromTargetLtv_alreadyBelowTarget_returnsZero() public pure {
        uint256 x = PMHLib.flashWithdrawAmountFromTargetLtv(LTV_25, 0.001e18, 0.01e18, 10 * WETH, 2_000 * USDT, PRICE);
        assertEq(x, 0, "no liquidation needed when already below target LTV");
    }

    /// @dev Zero debt → returns 0.
    function testFlashWithdrawAmountFromTargetLtv_zeroDebt_returnsZero() public pure {
        uint256 x = PMHLib.flashWithdrawAmountFromTargetLtv(LTV_25, 0.001e18, 0.01e18, 10 * WETH, 0, PRICE);
        assertEq(x, 0, "zero debt should return 0");
    }

    /// @dev Zero price → returns 0.
    function testFlashWithdrawAmountFromTargetLtv_zeroPrice_returnsZero() public pure {
        uint256 x = PMHLib.flashWithdrawAmountFromTargetLtv(LTV_25, 0.001e18, 0.01e18, 10 * WETH, 10_000 * USDT, 0);
        assertEq(x, 0, "zero price should return 0");
    }

    /// @dev When cost factor (slippage + premium) exceeds liquidation gain, target is unreachable.
    ///      Force this by setting slippage extremely high (99%).
    ///      Position: 10 WETH / 15 000 USDT = 75 % LTV, target 50 %.
    ///      With 99 % slippage: F ≈ 100 WAD → 1/F ≈ 0.01 WAD < ltv (0.5 WAD) → max uint.
    function testFlashWithdrawAmountFromTargetLtv_unreachableTarget_returnsMaxUint() public pure {
        uint64 extremeSlippage = 0.99e18; // 99%
        // Use 15 000 USDT debt (75 % LTV) so the position is above the 50 % target,
        // ensuring the function reaches the 1/F <= ltv check rather than early-returning 0.
        uint256 x =
            PMHLib.flashWithdrawAmountFromTargetLtv(LTV_50, 0.001e18, extremeSlippage, 10 * WETH, 15_000 * USDT, PRICE);
        assertEq(x, type(uint256).max, "unreachable target should return max uint");
    }

    /// @dev Consistency: the collateral returned by flashWithdrawAmountFromTargetLtv must
    ///      also satisfy the proceeds-cover invariant that flashWithdrawAmount guarantees —
    ///      i.e. selling x at worst-case price covers y * (1 + pr).
    ///
    ///      Note: the two functions are NOT algebraic inverses. Deriving y from x via floor
    ///      division and then passing y to flashWithdrawAmount yields a slightly smaller x
    ///      (by ~1 unit) because information is lost at the floor-division step. We therefore
    ///      verify the shared invariant rather than equality between the two x values.
    function testFlashWithdrawAmount_consistentWithTargetLtvVariant() public pure {
        uint256 c = 10 * WETH;
        uint256 d = 10_000 * USDT;
        uint64 ltv = LTV_25;
        uint64 pr = 0.001e18;
        uint64 f = 0.01e18;

        uint256 xFromLtv = PMHLib.flashWithdrawAmountFromTargetLtv(ltv, pr, f, c, d, PRICE);

        // Derive y from xFromLtv (same formula the caller uses after the LTV-targeting call).
        uint256 F = WAD.mulDiv(WAD + uint256(pr), WAD - uint256(f));
        uint256 y = xFromLtv.mulDiv(PRICE, RAY).mulDiv(WAD, F);

        // Shared invariant: proceeds from selling x at worst-case price must cover y * (1 + pr).
        uint256 proceedsAtWorstPrice = xFromLtv.mulDiv(PRICE, RAY).mulDiv(WAD - uint256(f), WAD);
        uint256 totalOwed = y.mulDiv(WAD + uint256(pr), WAD);
        assertApproxEqAbs(proceedsAtWorstPrice, totalOwed, 1, "xFromLtv proceeds must cover total owed");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 7. sellAmountForTargetLtv
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Finding example: 100 collateral / 80 debt at 1:1, target 50 % LTV.
    ///      `repayAmountForTargetLtv` with R = 0 (collateral held constant) sizes
    ///      the repayment at 30 and would land at ~71 % LTV. The sell-path formula
    ///      accounts for the collateral consumed by the sale and sizes it at 60,
    ///      landing at 50 %.
    function testSellAmountForTargetLtv_accountsForCollateralConsumedBySale() public pure {
        uint256 p = RAY; // 1:1 oracle price
        uint256 c = 100e18;
        uint256 d = 80e18;
        uint64 ltv = LTV_50;

        uint256 x = PMHLib.sellAmountForTargetLtv(p, ltv, c, d);
        assertEq(x, 60e18, "expected 60 collateral sold to reach 50% LTV");

        // Contrast: the repay-only formula (R = 0) under-sizes at 30.
        uint256 repayIfCollateralHeld = PMHLib.repayAmountForTargetLtv(p, ltv, c, 0, d);
        assertEq(repayIfCollateralHeld, 30e18, "held-collateral formula sizes repay at 30");

        uint256 y = x.mulDiv(p, RAY);
        uint256 remainingCollateralValue = (c - x).mulDiv(p, RAY);
        uint256 postSellLtv = (d - y).mulDiv(WAD, remainingCollateralValue);
        assertApproxEqAbs(postSellLtv, ltv, ROUNDING_TOL, "post-sell LTV should match target");
    }

    /// @dev Canonical fixture: 10 WETH / 16 000 USDT (80 % LTV) → 50 % LTV.
    ///      Correct sale = 6 WETH (repay 12 000 USDT) → 4 WETH / 4 000 USDT = 50 %.
    function testSellAmountForTargetLtv_canonicalFixture() public pure {
        uint256 c = 10 * WETH;
        uint256 d = 16_000 * USDT;
        uint64 ltv = LTV_50;

        uint256 x = PMHLib.sellAmountForTargetLtv(PRICE, ltv, c, d);
        assertEq(x, 6 * WETH, "expected 6 WETH sold to reach 50% LTV");

        uint256 y = x.mulDiv(PRICE, RAY);
        uint256 remainingCollateralValue = _collateralValue(c - x);
        uint256 postSellLtv = (d - y).mulDiv(WAD, remainingCollateralValue);
        assertApproxEqAbs(postSellLtv, ltv, ROUNDING_TOL, "post-sell LTV should match target");
    }

    /// @dev Already at or below target → 0.
    function testSellAmountForTargetLtv_alreadyBelowTarget_returnsZero() public pure {
        uint256 x = PMHLib.sellAmountForTargetLtv(PRICE, LTV_50, 10 * WETH, 5_000 * USDT);
        assertEq(x, 0, "no sale needed when already below target LTV");
    }

    /// @dev Zero debt → 0.
    function testSellAmountForTargetLtv_zeroDebt_returnsZero() public pure {
        assertEq(PMHLib.sellAmountForTargetLtv(PRICE, LTV_50, 10 * WETH, 0), 0, "zero debt returns 0");
    }

    /// @dev Zero price → 0.
    function testSellAmountForTargetLtv_zeroPrice_returnsZero() public pure {
        assertEq(PMHLib.sellAmountForTargetLtv(0, LTV_50, 10 * WETH, 10_000 * USDT), 0, "zero price returns 0");
    }

    /// @dev Consistency: sellAmountForTargetLtv is flashWithdrawAmountFromTargetLtv
    ///      with zero premium and zero slippage.
    function testSellAmountForTargetLtv_matchesZeroCostFlashPath() public pure {
        uint256 c = 10 * WETH;
        uint256 d = 16_000 * USDT;
        uint64 ltv = LTV_25;

        uint256 xSell = PMHLib.sellAmountForTargetLtv(PRICE, ltv, c, d);
        uint256 xFlash = PMHLib.flashWithdrawAmountFromTargetLtv(ltv, 0, 0, c, d, PRICE);
        assertEq(xSell, xFlash, "sell-path sizing must match zero-cost flash path");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 8. redepositAmount
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev 10 WETH collateral, 10 000 USDT debt (50 % LTV), withdraw 5 WETH, repay 3 000 USDT.
    ///      After: 5 WETH collateral, 7 000 USDT debt → LTV = 70 %.
    ///      To stay at 50 % with 5 WETH: target debt = 5 * 2 000 * 0.5 = 5 000 USDT.
    ///      Remaining debt after repay = 7 000 → redeposit not needed (7 000 > 5 000).
    ///      Expected: 0.
    function testRedepositAmount_noRedepositNeeded() public pure {
        uint256 redeposit = PMHLib.redepositAmount(PRICE, LTV_50, 10 * WETH, 5 * WETH, 10_000 * USDT, 3_000 * USDT);
        assertEq(redeposit, 0, "redeposit should be 0 when remaining debt exceeds target");
    }

    /// @dev 10 WETH collateral, 10 000 USDT debt (50 % LTV), withdraw 2 WETH, repay 8 000 USDT.
    ///      After repay: remaining debt = 2 000 USDT. Remaining collateral = 8 WETH.
    ///      Target debt at 50 % on 8 WETH = 8 000 USDT.
    ///      Redeposit = 8 000 − 2 000 = 6 000 USDT.
    ///      Reverse: (remainingDebt + redeposit) / (newCollateral * PRICE / RAY) == ltv.
    function testRedepositAmount_normalCase() public pure {
        uint256 c = 10 * WETH;
        uint256 d = 10_000 * USDT;
        uint256 R = 2 * WETH;
        uint256 y = 8_000 * USDT;
        uint64 ltv = LTV_50;

        uint256 redeposit = PMHLib.redepositAmount(PRICE, ltv, c, R, d, y);

        assertEq(redeposit, 6_000 * USDT, "expected 6 000 USDT redeposit");

        // Reverse: final debt / final collateral value == ltv
        uint256 finalDebt = (d - y) + redeposit;
        uint256 finalCollateralValue = _collateralValue(c - R);
        uint256 derivedLtv = finalDebt.mulDiv(WAD, finalCollateralValue);
        assertApproxEqAbs(derivedLtv, ltv, ROUNDING_TOL, "reverse LTV check failed for redeposit");
    }

    /// @dev Withdrawing all collateral (R >= c) → redeposit = 0 (no position left).
    function testRedepositAmount_fullWithdrawal_returnsZero() public pure {
        uint256 r = PMHLib.redepositAmount(PRICE, LTV_50, 10 * WETH, 10 * WETH, 10_000 * USDT, 5_000 * USDT);
        assertEq(r, 0, "full withdrawal should return 0 redeposit");
    }

    /// @dev Zero price → 0.
    function testRedepositAmount_zeroPrice_returnsZero() public pure {
        assertEq(PMHLib.redepositAmount(0, LTV_50, 10 * WETH, 2 * WETH, 10_000 * USDT, 8_000 * USDT), 0);
    }

    /// @dev Zero ltv → 0.
    function testRedepositAmount_zeroLtv_returnsZero() public pure {
        assertEq(PMHLib.redepositAmount(PRICE, 0, 10 * WETH, 2 * WETH, 10_000 * USDT, 8_000 * USDT), 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 9. Cross-function invariants
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev borrowAmountForTargetLtv and repayAmountForTargetLtv are mirrors.
    ///      Starting from the same position, borrow to 50 % then repay back to 25 % —
    ///      net debt change must cancel out.
    function testCrossFunction_borrowAndRepayAreSymmetric() public pure {
        uint256 c = 10 * WETH;
        uint256 d = 5_000 * USDT; // 25% LTV

        // Borrow up to 50%
        uint256 borrow = PMHLib.borrowAmountForTargetLtv(PRICE, LTV_50, c, 0, d);
        uint256 debtAfterBorrow = d + borrow; // should be 10 000 USDT

        // Repay back to 25% (no withdrawal)
        uint256 repay = PMHLib.repayAmountForTargetLtv(PRICE, LTV_25, c, 0, debtAfterBorrow);

        // Net should cancel: borrow == repay
        assertEq(borrow, repay, "borrow to 50% and repay to 25% should be symmetric");
    }

    /// @dev minLtv and borrowAmountForTargetLtv are consistent:
    ///      if targetLtv > minLtv then borrow > 0, if targetLtv <= minLtv then borrow == 0.
    function testCrossFunction_minLtvGatesBorrowAmount() public pure {
        uint256 c = 10 * WETH;
        uint256 d = 5_000 * USDT; // 25% current LTV
        uint256 x = 0; // no additional supply

        uint256 currentMinLtv = PMHLib.minLtv(d, c, x, PRICE);

        // Target above current: borrow needed
        uint256 borrowAbove = PMHLib.borrowAmountForTargetLtv(PRICE, LTV_50, c, x, d);
        assertGt(uint256(LTV_50), currentMinLtv, "LTV_50 should be above minLtv");
        assertGt(borrowAbove, 0, "borrow should be positive when target > minLtv");

        // Target below current: no borrow
        uint256 borrowBelow = PMHLib.borrowAmountForTargetLtv(PRICE, LTV_25, c, x, d);
        assertEq(borrowBelow, 0, "borrow should be 0 when target <= minLtv");
    }
}
