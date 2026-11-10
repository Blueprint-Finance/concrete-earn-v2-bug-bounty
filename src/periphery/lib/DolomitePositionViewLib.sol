// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";

import {IDolomiteMargin, DolomiteAccount} from "../interface/IDolomiteMargin.sol";
import {ILiquidationModule, Liquidation} from "../interface/ILiquidationModule.sol";
import {WAD, RAY} from "./Constants.sol";

/// @title  DolomitePositionViewLib
/// @notice Position/LTV/rate view math shared by every Dolomite position-helper flavour
///         (`PositionHelperDolomiteNative`, `PositionHelperDolomiteAssetCX`).
/// @dev Deployed as an external library and called via `DELEGATECALL` — every function here is
///      `public` rather than `internal` specifically so this logic is compiled once into the
///      library's own bytecode instead of being inlined into each flavour's contract. That
///      inlining was pushing both flavours over the EIP-170 24,576-byte runtime size limit.
///      Pure math, no state; callers pass in whatever context (DolomiteMargin, positionOwner,
///      market ids) they'd otherwise have read from their own immutables/clone args.
library DolomitePositionViewLib {
    using Math for uint256;
    using SafeCast for uint256;

    /// @dev Dolomite's oracle returned 0 for `marketId` (paused, migrated, stale, or misconfigured
    ///      feed). Guards `collateralPriceInBorrowTokensInRay` against dividing by zero or
    ///      silently returning zero, matching the zero-price guards in
    ///      `PositionHelperAaveV3.collateralPriceInBorrowTokensInRay` / `PositionHelperMorpho`'s.
    error ZeroMarketPrice(uint256 marketId);

    /// @dev Collateral held in `accountNr` in token units. 0 if the balance is negative
    ///      (should not happen for a collateral market).
    function getCollateralAmount(
        IDolomiteMargin dolomiteMargin,
        address positionOwner,
        uint256 accountNr,
        uint256 collateralMarketId
    ) public view returns (uint256) {
        (bool sign, uint256 value) = dolomiteMargin.getAccountWei(
            DolomiteAccount.Info({owner: positionOwner, number: accountNr}), collateralMarketId
        );
        return sign ? value : 0;
    }

    /// @dev Debt owed in `accountNr` in token units. 0 if the balance is positive (no borrow).
    function getDebtAmount(
        IDolomiteMargin dolomiteMargin,
        address positionOwner,
        uint256 accountNr,
        uint256 borrowMarketId
    ) public view returns (uint256) {
        (bool sign, uint256 value) = dolomiteMargin.getAccountWei(
            DolomiteAccount.Info({owner: positionOwner, number: accountNr}), borrowMarketId
        );
        return sign ? 0 : value;
    }

    /// @dev Current LTV for `accountNr` in WAD, computed from USD account values.
    ///      Uses getAccountValues which prices all assets in the account — accurate only
    ///      when the account holds exactly the collateral and borrow token and nothing else.
    function getCurrentLtvInWad(IDolomiteMargin dolomiteMargin, address positionOwner, uint256 accountNr)
        public
        view
        returns (uint64)
    {
        (uint256 supplyValue, uint256 borrowValue) =
            dolomiteMargin.getAccountValues(DolomiteAccount.Info({owner: positionOwner, number: accountNr}));
        if (supplyValue == 0) return 0;
        return Math.min(borrowValue.mulDiv(WAD, supplyValue), type(uint64).max).toUint64();
    }

    /// @dev Effective margin ratio for `accountNr` in WAD, combining three mutable layers:
    ///
    ///   1. Account-level: `getMarginRatioForAccount` returns the per-account override if set
    ///      by Dolomite governance (used for isolation-mode vault addresses), otherwise global.
    ///   2. Collateral market premium: `getMarketMarginPremium(collateralMarketId)` — governance
    ///      can add a premium for volatile or risky collateral assets.
    ///   3. Borrow market premium: `getMarketMarginPremium(borrowMarketId)` — same for borrow.
    ///
    ///   Effective formula (mirrors Storage.sol getAccountValues with adjustForLiquidity=true):
    ///     effective = (1 + base) × (1 + collPremium) × (1 + borrowPremium) − 1
    ///
    ///   The liquidation threshold LTV = WAD / (WAD + effectiveMarginRatio).
    ///   Since all three parameters are governance-mutable, this must be read on-chain each time.
    function getMarginRatio(
        IDolomiteMargin dolomiteMargin,
        address positionOwner,
        uint256 accountNr,
        uint256 collateralMarketId,
        uint256 borrowMarketId
    ) public view returns (uint256) {
        uint256 base = dolomiteMargin.getMarginRatioForAccount(
            DolomiteAccount.Info({owner: positionOwner, number: accountNr})
        );
        uint256 collPremium = dolomiteMargin.getMarketMarginPremium(collateralMarketId);
        uint256 borrowPremium = dolomiteMargin.getMarketMarginPremium(borrowMarketId);
        // (1 + base) * (1 + collPremium) * (1 + borrowPremium) - 1, all in WAD
        return (WAD + base).mulDiv(WAD + collPremium, WAD).mulDiv(WAD + borrowPremium, WAD) - WAD;
    }

    /// @dev Liquidation threshold = WAD / (WAD + effectiveMarginRatio).
    ///      An account becomes liquidatable when its LTV exceeds this value.
    function getLiquidationThresholdForAccount(
        IDolomiteMargin dolomiteMargin,
        address positionOwner,
        uint256 accountNr,
        uint256 collateralMarketId,
        uint256 borrowMarketId
    ) public view returns (uint64) {
        uint256 marginRatio = getMarginRatio(
            dolomiteMargin, positionOwner, accountNr, collateralMarketId, borrowMarketId
        );
        return WAD.mulDiv(WAD, WAD + marginRatio).toUint64();
    }

    /// @dev Borrow-token wei per collateral wei, in RAY (1e27 = 1.0) — the convention every
    ///      `PMHLib` helper consumes (`collateralAmount.mulDiv(price, RAY)` on raw amounts).
    ///
    ///      Dolomite quotes each market at `36 − tokenDecimals` precision, chosen precisely so that
    ///      `rawAmount · price` is a USD value scaled by 1e36. The price is therefore already
    ///      *per wei*, and the wei-to-wei rate is the bare ratio — do NOT rescale by token
    ///      decimals. Scaling by `10**(cDec − bDec)` would instead yield whole-borrow-tokens per
    ///      whole-collateral-token, overstating collateral by that factor.
    ///
    ///      Worked example (mainnet, block 25.1M — WETH collateral, USDC borrow):
    ///        cPrice = 2255.1102e18 (36−18), bPrice = 0.99970386e30 (36−6)
    ///        1 WETH wei = $2.2551e-15 → 2.2558e-9 USDC wei → 2.2558e18 in RAY.
    ///      The result is below RAY because an 18-decimal wei is worth less than a 6-decimal wei.
    ///
    ///      Contrast `PositionHelperAaveV3`, which scales by `10**bDec / 10**cDec`: Aave's oracle
    ///      quotes per *whole token*, so it has to be converted down to per-wei. Same identity,
    ///      opposite starting convention.
    ///
    ///      No overflow: `Math.mulDiv` carries the full 512-bit product, so `cPrice · RAY` never
    ///      needs to fit in a uint256 — only the quotient does, and that stays ~26 orders of
    ///      magnitude below `type(uint256).max` for any realistic price pair.
    function collateralPriceInBorrowTokensInRay(
        IDolomiteMargin dolomiteMargin,
        uint256 collateralMarketId,
        uint256 borrowMarketId
    ) public view returns (uint256) {
        uint256 cPrice = dolomiteMargin.getMarketPrice(collateralMarketId);
        if (cPrice == 0) revert ZeroMarketPrice(collateralMarketId);
        uint256 bPrice = dolomiteMargin.getMarketPrice(borrowMarketId);
        if (bPrice == 0) revert ZeroMarketPrice(borrowMarketId);
        return cPrice.mulDiv(RAY, bPrice);
    }

    /// @dev Annualised borrow interest rate on `borrowMarketId`, in WAD (1e18 = 100% APR).
    function getBorrowRateInWad(IDolomiteMargin dolomiteMargin, uint256 borrowMarketId) public view returns (uint64) {
        return dolomiteMargin.getMarketBorrowInterestRateApr(borrowMarketId).toUint64();
    }

    /// @dev Annualised supply interest rate earned on `collateralMarketId`, in WAD (1e18 = 100% APR).
    function getSupplyRateInWad(IDolomiteMargin dolomiteMargin, uint256 collateralMarketId)
        public
        view
        returns (uint64)
    {
        return dolomiteMargin.getMarketSupplyInterestRateApr(collateralMarketId).toUint64();
    }

    /// @dev Sums the `marketId` account-wei balance across every active liquidation's
    ///      module-owned temporary position, filtered to `wantSign` (true = supplied, false =
    ///      owed). Used to aggregate redemption-claim-token supply/debt that's temporarily
    ///      parked in per-liquidation sub-accounts owned by `liquidationModule` itself.
    function sumActiveLiquidationMarketBalances(
        IDolomiteMargin dolomiteMargin,
        ILiquidationModule liquidationModule,
        address positionOwner,
        uint256 accountNr,
        uint256 marketId,
        bool wantSign
    ) public view returns (uint256 amount) {
        address module = address(liquidationModule);
        uint256[] memory ids = liquidationModule.getLiquidationIds(positionOwner, accountNr);
        for (uint256 i = 0; i < ids.length; ++i) {
            Liquidation memory liq = liquidationModule.getLiquidation(ids[i]);
            if (!liq.active) continue;
            (bool sign, uint256 value) = dolomiteMargin.getAccountWei(
                DolomiteAccount.Info({owner: module, number: liq.tempAccountNumber}), marketId
            );
            if (sign == wantSign) amount += value;
        }
    }

    /// @dev Available borrow-token liquidity = actual token balance held by DolomiteMargin.
    ///      Dolomite holds real tokens directly (no aToken indirection), so the protocol
    ///      contract balance is the canonical borrowable ceiling, analogous to
    ///      `IERC20(borrowToken).balanceOf(aTokenAddress)` on Aave V3.
    function getAvailablePoolLiquidity(IDolomiteMargin dolomiteMargin, address borrowToken)
        public
        view
        returns (uint256)
    {
        return IERC20(borrowToken).balanceOf(address(dolomiteMargin));
    }

    /// @dev True when `accountNr` holds at most one market with a positive balance (and it is
    ///      `collateralMarketId`), and at most one market with a negative balance (and it is
    ///      `borrowMarketId`). Zero balances on either side are allowed. Dolomite only reports a
    ///      count of non-zero-balance markets, not their identity, so each side is paired with an
    ///      identity check on the specific market's balance.
    ///
    ///      Backs the single-collateral, single-debt assumption behind `getCurrentLtvInWad`
    ///      combined with `getLiquidationThresholdForAccount`: the former sums USD value across
    ///      every market the account holds, while the latter derives its threshold only from
    ///      `collateralMarketId`/`borrowMarketId`'s margin premiums. Those two only agree when
    ///      this returns `(true, true)`.
    function isSingleCollateralAndDebtMarket(
        IDolomiteMargin dolomiteMargin,
        address positionOwner,
        uint256 accountNr,
        uint256 collateralMarketId,
        uint256 borrowMarketId
    ) public view returns (bool singleCollateral, bool singleDebt) {
        DolomiteAccount.Info memory account = DolomiteAccount.Info({owner: positionOwner, number: accountNr});
        uint256 numberOfMarketsWithBalances = dolomiteMargin.getAccountNumberOfMarketsWithBalances(account);
        uint256 numberOfMarketsWithDebt = dolomiteMargin.getAccountNumberOfMarketsWithDebt(account);
        uint256 numberOfMarketsWithCollateral = numberOfMarketsWithBalances - numberOfMarketsWithDebt;

        singleCollateral = true;
        if (numberOfMarketsWithCollateral > 0) {
            (bool isPositive, uint256 value) = dolomiteMargin.getAccountWei(account, collateralMarketId);
            singleCollateral = numberOfMarketsWithCollateral == 1 && isPositive && value > 0;
        }

        singleDebt = true;
        if (numberOfMarketsWithDebt > 0) {
            (bool isPositive, uint256 value) = dolomiteMargin.getAccountWei(account, borrowMarketId);
            singleDebt = numberOfMarketsWithDebt == 1 && !isPositive && value > 0;
        }
    }
}
