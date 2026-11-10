// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {
    TokenPair,
    FlashLoanParams,
    LeverageData,
    FlashQuote,
    NewLtvResult
} from "../../interface/ILoopingPrimitive.sol";
import {LoopModalityLib, LoopModality} from "./LoopModalityLib.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {LoopingPrimitiveErrors} from "./LoopingPrimitiveErrors.sol";
import {IFlashModule} from "../../interface/IFlashModule.sol";
import {ErrorInfoLib, ErrorInfo} from "../ErrorInfoLib.sol";
import {WAD, RAY} from "../Constants.sol";

library LoopingPrimitiveLib {
    using Math for uint256;
    using SafeCast for uint256;
    using LoopModalityLib for LoopModality;
    using ErrorInfoLib for ErrorInfo;

    //----------------------------------------------------------
    // Leverage Data And Quote Functions
    //----------------------------------------------------------

    function getLeverageModalityAndData(
        FlashLoanParams memory params,
        address flashModule,
        TokenPair memory tokenPair,
        LoopModality loopModality
    ) public view returns (LoopModality, LeverageData memory) {
        return _leverageData(params, flashModule, tokenPair, loopModality, false);
    }

    function leverageData(
        FlashLoanParams memory params,
        address flashModule,
        TokenPair memory tokenPair,
        LoopModality loopModality
    )
        public
        view
        returns (
            uint256 flashAmount,
            uint256 pairedTokenAmount,
            LoopModality newLoopModality,
            uint256 floatingAmount,
            uint256 collateralDiff,
            uint256 debtDiff
        )
    {
        LeverageData memory returnData;
        (newLoopModality, returnData) = _leverageData(params, flashModule, tokenPair, loopModality, true);
        return (
            returnData.flashAmount,
            returnData.pairedTokenAmount,
            newLoopModality,
            returnData.floatingAmount,
            returnData.collateralDiff,
            returnData.debtDiff
        );
    }

    function _leverageData(
        FlashLoanParams memory params,
        address flashModule,
        TokenPair memory tokenPair,
        LoopModality loopModality,
        bool checkFlashLtvAndLiquidityBounds
    ) internal view returns (LoopModality newLoopModality, LeverageData memory returnData) {
        // 1. update looping mode
        // It checks whether this allocation or deallocation requires a flash on the collateral to wind up, or a flash on the debt to wind down.
        // or wehther it just requires a plain supply or withdraw, i.e. a plain operation.
        newLoopModality = _updateLoopModality(params, loopModality);

        // 2. check whether its a plain operation (i.e. plain supply or plain withdraw) or whether it requires a flash loan.
        if (newLoopModality.plainOperation()) {
            returnData.floatingAmount = params.floatingAmount;
            returnData.collateralDiff = params.floatingAmount;
            returnData.newEquity = newLoopModality.loopSupply()
                ? params.collateralAmount + params.floatingAmount
                : params.collateralAmount - params.floatingAmount;
            return (newLoopModality, returnData);
        }
        // 3. load flash token and cache floating amount (= for allocation and repayment the floating amount has to be adjusted)
        address token = newLoopModality.loopSupply() ? tokenPair.collateralToken : tokenPair.borrowToken;
        uint256 floatingAmountIntended = params.floatingAmount;

        // 4. get quotes.
        // get depth of liquidity. Also get asset and premium quote
        // depending on the flash token either collateral amount or debt amount is the flashable amount
        // the other amount is the paired token amount
        // the paired token amount is used to either modify debt if flash is collateral
        // or modify collateral if flash is in debt.
        (FlashQuote memory flashQuote, ErrorInfo errorInfo) =
            _getFlashQuote(params, flashModule, token, newLoopModality);
        returnData.errorInfo = errorInfo;

        // 6. Adjust flash quote if max withdraw is requested. Ensures that no Wei of debt is left in the position.
        if (flashQuote.isMaxWithdraw) {
            newLoopModality = newLoopModality.setMaxWithdraw(true);
            // adjust collateralQuote and debtQuote
            flashQuote.collateralAmount = params.collateralAmount - params.floatingAmount;
            flashQuote.debtAmount = params.debtAmount;
        }

        // 7. if we are not checking flash ltv and liquidity bounds, and there is an error, return the new loop modality and return data
        if (errorInfo.hasError()) {
            if (!checkFlashLtvAndLiquidityBounds) {
                return (newLoopModality, returnData);
            }
            if (errorInfo.hasError(0)) {
                revert LoopingPrimitiveErrors.TargetLtvUpperBoundReached(
                    newLoopModality, params.targetLtvInWad, errorInfo.wadPayload(0)
                );
            }
            if (errorInfo.hasError(1)) {
                // Dewadify the stored deallocation upper bound to get the actual value
                // If collateralAmount is zero, the wad payload will be 0, so dewadify will return 0
                uint256 deallocationUpperBound =
                    params.collateralAmount > 0 ? _dewadify(errorInfo.wadPayload(1), params.collateralAmount) : 0;
                revert LoopingPrimitiveErrors.DeallocationUpperBoundReached(
                    newLoopModality, params.floatingAmount, deallocationUpperBound
                );
            }
        }

        // 8. check if any ltv bound has been reached or required flash liquidity cannot be serviced by current flash loan provider(s).
        // If this is for a quote such as the one used to report the value of the position (which should be non-reverting)
        // then this exits the query and bubbles up the issue to the calling context.
        // for reporting the equity of the position, the relevant quote checks the cost of unwinding the position to zero ltv,
        // so that this early exit is not relevant for it. It is only relevant for quoting the cost of an operation.

        uint256 flashAmount = newLoopModality.loopSupply() ? flashQuote.collateralAmount : flashQuote.debtAmount;

        if (flashAmount > flashQuote.depthOfLiquidity) {
            returnData.errorInfo = returnData.errorInfo.setError(2, true);
            // Note: We intentionally leave the wad payload as 0 for insufficient flash liquidity errors.
            // Normalizing depthOfLiquidity against collateralAmount would be inaccurate when flashing
            // borrow tokens (where debtAmount would be the appropriate denominator), and the error
            // already contains the absolute values (flashAmount, depthOfLiquidity) in the revert message.
            if (checkFlashLtvAndLiquidityBounds) {
                revert LoopingPrimitiveErrors.InsufficientFlashLiquidity(
                    token, flashAmount, flashQuote.depthOfLiquidity
                );
            }
            // if we dont check the bounds then we may still continue to get the hypothetical quote or the equity etc.
            // This error only affects the execution of the operation, but not the quote.
        }

        // 9. update the flash parameter and return data.
        // the return data contains changes (diffs) of the position regarding collateral or debt after the operation.
        // the parameters are updated accordingly to reflect the updated collateral or debt after the operation (accounting for diffs).
        updateFlashParamsAndReturnData(
            params,
            returnData,
            newLoopModality,
            flashQuote.collateralAmount,
            flashQuote.debtAmount,
            flashQuote.flashPremiumQuoteInWad
        );
        // 10. get the equity of the new position.
        // By construction we have no borrow tokens in the position at the beginning and end of the operation
        // We only may have a surplus of floating amount in collateral tokens.
        // If the intention was an allocation, then params.floatingAmount is the amount of assets to be added to the position.
        // If the intention was a deallocation, then the params.floatingAmount is the amount of assets to be subtracted from the position.
        // In either case the diff has to be accounted in the equity.
        // Note: returnData.newEquity does NOT include staged liquidity at the lender module
        uint256 floatingSurplusAfterOperation = newLoopModality.allocateFloating()
            ? floatingAmountIntended - params.floatingAmount
            : params.floatingAmount - floatingAmountIntended;
        returnData.newEquity = _getEquity(
            params.collateralAmount + floatingSurplusAfterOperation, params.debtAmount, params.collateralPriceInRay
        );
        returnData.floatingAmount = params.floatingAmount;
        return (newLoopModality, returnData);
    }

    /**
     * @notice Get the flash quote for the given parameters.
     * @param params The flash loan parameters (collateral amount, debt amount, floating amount, collateral price in ray, target ltv in wad, max slippage in wad)
     * @param flashModule The flash module address.
     * @param token The token address.
     * @param loopModality The loop modality.
     * @return The flash quote and error information.
     */
    function _getFlashQuote(
        FlashLoanParams memory params,
        address flashModule,
        address token,
        LoopModality loopModality
    ) internal view returns (FlashQuote memory, ErrorInfo) {
        uint256 depthOfLiquidity = IFlashModule(flashModule).depthOfFlashLiquidityExact(token);
        (
            uint256 collateralAmount,
            uint256 debtAmount,
            uint64 flashPremiumQuoteInWad,
            ErrorInfo errorInfo,
            bool isMaxWithdraw
        ) = getAssetAndPremiumQuote(params, flashModule, token, loopModality);
        return
            (
                FlashQuote(depthOfLiquidity, collateralAmount, debtAmount, flashPremiumQuoteInWad, isMaxWithdraw),
                errorInfo
            );
    }

    function getAssetAndPremiumQuote(
        FlashLoanParams memory params,
        address flashModule,
        address tokenAddress,
        LoopModality loopModality
    )
        internal
        view
        returns (
            uint256 collateralAmount,
            uint256 debtAmount,
            uint64 flashPremiumQuoteInWad,
            ErrorInfo errorInfo,
            bool isMaxWithdraw
        )
    {
        // 1. fetch flash premium quote
        // initial guess (overestimated because of max premium)
        bool premiumDependsOnLiquidity;
        (flashPremiumQuoteInWad, premiumDependsOnLiquidity) =
            IFlashModule(flashModule).flashPremiumMaxInWad(tokenAddress);
        function(FlashLoanParams memory, uint64) internal view returns (uint256, uint256) quoteFn;
        bool allocate = loopModality.allocateFloating();
        bool loopSupply = loopModality.loopSupply();
        if (allocate && loopSupply) {
            quoteFn = allocFloatingAndLoopSupply;
        } else if (allocate && !loopSupply) {
            quoteFn = allocFloatingAndLoopRepay;
        } else if (!allocate && loopSupply) {
            quoteFn = deallocFloatingAndLoopSupply;
        } else {
            quoteFn = deallocFloatingAndLoopRepay;
        }

        (errorInfo, isMaxWithdraw) =
            _handleLimitsFromPremiumQuotes(params, allocate, loopSupply, errorInfo, flashPremiumQuoteInWad);
        if (errorInfo.hasError()) return (0, 0, flashPremiumQuoteInWad, errorInfo, isMaxWithdraw);
        (collateralAmount, debtAmount) = quoteFn(params, flashPremiumQuoteInWad);
        // 2. if flash premium depends on liquidity, fetch more accurate quote
        // Note: When premiumDependsOnLiquidity is true, we recalculate the premium and call
        // _handleLimitsFromPremiumQuotes again. For the allocate + loopRepay case, params.floatingAmount
        // may have been capped in the first call. This is safe because allocationLowerBound and flash
        // premium are positively related (both increase or decrease together). If floatingAmount was
        // capped at the worst-case premium, it will also be capped (or capped further) at the lower
        // liquidity-dependent premium. The order of capping doesn't matter - starting with the adjusted
        // premium would yield the same result. See section 10.4 "Allocate & Loop Repay" in the docs.
        if (premiumDependsOnLiquidity) {
            flashPremiumQuoteInWad = IFlashModule(flashModule)
                .flashPremiumQuoteInWad(
                    tokenAddress,
                    loopSupply ? collateralAmount : debtAmount /* flashAmount */
                );
            (errorInfo, isMaxWithdraw) =
                _handleLimitsFromPremiumQuotes(params, allocate, loopSupply, errorInfo, flashPremiumQuoteInWad);
            if (errorInfo.hasError()) return (0, 0, flashPremiumQuoteInWad, errorInfo, isMaxWithdraw);
            (collateralAmount, debtAmount) = quoteFn(params, flashPremiumQuoteInWad);
        }
    }

    function _handleLimitsFromPremiumQuotes(
        FlashLoanParams memory params,
        bool allocate,
        bool loopSupply,
        ErrorInfo errorInfo,
        uint64 flashPremiumQuoteInWad
    ) internal pure returns (ErrorInfo, bool) {
        bool isMaxWithdraw = false;
        if (!loopSupply && allocate) {
            params.floatingAmount =
                Math.min(params.floatingAmount, allocationLowerBound(params, flashPremiumQuoteInWad));
        }
        if (!loopSupply && !allocate) {
            uint64 targetLtvUpperBound_ = targetLtvUpperBound(params, flashPremiumQuoteInWad);
            if (params.targetLtvInWad > targetLtvUpperBound_) {
                return (errorInfo.setError(0, true).setWadPayload(0, targetLtvUpperBound_), false);
            }
            uint256 deallocationUpperBound_ = criticalDeallocation(params, flashPremiumQuoteInWad);
            // Max withdraw is triggered when:
            // 1. Floating amount equals the deallocation upper bound (exact match)
            // 2. Target LTV is zero and there's debt (complete unwind requested)
            //    This ensures no wei of debt remains, even if floatingAmount doesn't exactly match
            //    deallocationUpperBound_ due to rounding/precision
            isMaxWithdraw = params.floatingAmount == deallocationUpperBound_
                || (params.targetLtvInWad == 0 && params.debtAmount != 0);
            if (params.floatingAmount > deallocationUpperBound_) {
                // Store the deallocation upper bound as a WAD-normalized value against collateralAmount
                // This allows the error message to display the bound by dewadifying it
                // Note: If collateralAmount is zero, deallocationUpperBound_ will also be zero, so wadPayload will be 0
                uint64 wadPayload =
                    params.collateralAmount > 0 ? _wadify(deallocationUpperBound_, params.collateralAmount) : 0;
                return (errorInfo.setError(1, true).setWadPayload(1, wadPayload), false);
            }
        }
        return (errorInfo, isMaxWithdraw);
    }

    //----------------------------------------------------------
    // Update Functions
    //----------------------------------------------------------

    function updateFlashParamsAndReturnData(
        FlashLoanParams memory params,
        LeverageData memory returnData,
        LoopModality newLoopModality,
        uint256 collateralAmountQuote,
        uint256 debtAmountQuote,
        uint64 flashPremiumQuoteInWad
    ) internal pure {
        returnData.flashPremiumQuoteInWad = flashPremiumQuoteInWad;
        returnData.debtDiff = debtAmountQuote;
        bool isSupply = newLoopModality.loopSupply();
        if (isSupply) {
            returnData.flashAmount = collateralAmountQuote;
            returnData.pairedTokenAmount = debtAmountQuote;
            if (newLoopModality.allocateFloating()) {
                returnData.collateralDiff = collateralAmountQuote + params.floatingAmount;
            } else {
                returnData.collateralDiff = collateralAmountQuote - params.floatingAmount;
            }
        } else {
            returnData.flashAmount = debtAmountQuote;
            returnData.pairedTokenAmount = collateralAmountQuote;
            if (newLoopModality.allocateFloating()) {
                returnData.collateralDiff = collateralAmountQuote;
            } else {
                returnData.collateralDiff = collateralAmountQuote + params.floatingAmount;
            }
        }
        updateFlashParamsWithDiffs(params, isSupply, returnData.collateralDiff, returnData.debtDiff);
    }

    function updateFlashParamsWithDiffs(
        FlashLoanParams memory params,
        bool isSupply,
        uint256 collateralDiff,
        uint256 debtDiff
    ) internal pure {
        if (isSupply) {
            params.collateralAmount += collateralDiff;
            params.debtAmount += debtDiff;
        } else {
            params.collateralAmount -= collateralDiff;
            params.debtAmount -= debtDiff;
        }
    }

    function _updateLoopModality(FlashLoanParams memory params, LoopModality loopModality)
        internal
        pure
        returns (LoopModality)
    {
        // 1. store current LTV in wad
        uint64 currentLtvInWad_ = currentLtvInWad(params);
        // 2. check whether we are allocating or deallocating and whether we are raising or lowering LTV.
        if (loopModality.allocateFloating() && (params.targetLtvInWad >= currentLtvInWad_)) {
            // allocate entire floating amount and raise ltv by looping supply
            return loopModality.setLoopSupply(true).setPlainOperation(false);
        } else if (loopModality.allocateFloating() && (params.targetLtvInWad < currentLtvInWad_)) {
            uint256 allocationUpperBound_ = allocationUpperBound(params);
            if (params.floatingAmount > allocationUpperBound_) {
                // Loop supply with allocation of entire floating amount
                return loopModality.setLoopSupply(true).setPlainOperation(false);
            } else if (params.floatingAmount < allocationUpperBound_) {
                // Loop repay with allocation of maximum allowed floating amount
                return loopModality.setLoopSupply(false).setPlainOperation(false);
            } else {
                // exact amount to reach target LTV by plainly supplying floating amount
                return loopModality.setLoopSupply(true).setPlainOperation(true);
            }
        } else if (!loopModality.allocateFloating() && (params.targetLtvInWad <= currentLtvInWad_)) {
            // deallocate entire floating amount and loop repay to lower Ltv
            return loopModality.setLoopSupply(false).setPlainOperation(false);
        } else if (!loopModality.allocateFloating() && (params.targetLtvInWad > currentLtvInWad_)) {
            uint256 deallocationBound_ = deallocationBound(params);
            if (params.floatingAmount > deallocationBound_) {
                // loop repay with deallocation of entire floating amount to raise Ltv
                return loopModality.setLoopSupply(false).setPlainOperation(false);
            } else if (params.floatingAmount < deallocationBound_) {
                // loop supply with deallocation of entire floating amount
                return loopModality.setLoopSupply(true).setPlainOperation(false);
            } else {
                // exact amount to reach target LTV by plainly withdrawing floating amount
                return loopModality.setLoopSupply(false).setPlainOperation(true);
            }
        } else {
            // never reached here !
            return loopModality;
        }
    }

    //----------------------------------------------------------
    //  Position Related Functions
    //----------------------------------------------------------

    function currentLtvInWad(FlashLoanParams memory params) internal pure returns (uint64) {
        return _currentLtvInWad(params.collateralAmount, params.debtAmount, params.collateralPriceInRay);
    }

    function lenderPositionValue(
        address flashModule,
        address borrowToken,
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 collateralPriceInRay,
        uint64 maxSlippageInWad
    ) internal view returns (uint256) {
        return _positionValue(
            debtAmount,
            collateralAmount,
            collateralPriceInRay,
            IFlashModule(flashModule).flashPremiumQuoteInWad(borrowToken, debtAmount),
            maxSlippageInWad
        );
    }

    function _positionValue(
        uint256 debtAmount,
        uint256 collateralAmount,
        uint256 collateralPriceInRay,
        uint64 premiumForFlashingDebtAmountInWad,
        uint64 maxSlippageInWad
    ) internal pure returns (uint256) {
        uint256 effectiveCollateralValueOfDebt = _effectiveCollateralValueOfDebt(
            debtAmount, collateralPriceInRay, premiumForFlashingDebtAmountInWad, maxSlippageInWad
        );
        if (effectiveCollateralValueOfDebt >= collateralAmount) return 0;
        return collateralAmount - effectiveCollateralValueOfDebt;
    }

    //----------------------------------------------------------
    // Loop Functions Solving For Collateral And Debt Amounts
    //----------------------------------------------------------

    function deallocFloatingAndLoopRepay(FlashLoanParams memory params, uint64 premiumInWad)
        internal
        pure
        returns (uint256 collateralAmount, uint256 debtAmount)
    {
        uint256 OneOverF = WAD.mulDiv(WAD, _F(premiumInWad, params.maxSlippageInWad), Math.Rounding.Ceil);
        uint256 collateral_num = params.debtAmount.mulDiv(RAY, params.collateralPriceInRay, Math.Rounding.Ceil)
            - uint256(params.targetLtvInWad).mulDiv(params.collateralAmount - params.floatingAmount, WAD);
        uint256 collateral_denom = OneOverF - uint256(params.targetLtvInWad);
        collateralAmount = collateral_num.mulDiv(WAD, collateral_denom, Math.Rounding.Ceil);
        debtAmount = _convertXToY(OneOverF, collateralAmount, params.collateralPriceInRay);
    }

    function deallocFloatingAndLoopSupply(FlashLoanParams memory params, uint64 premiumInWad)
        internal
        pure
        returns (uint256 collateralAmount, uint256 debtAmount)
    {
        uint256 F = _F(premiumInWad, params.maxSlippageInWad);
        uint256 collateral_num = uint256(params.targetLtvInWad)
            .mulDiv(params.collateralAmount - params.floatingAmount, WAD)
        - params.debtAmount.mulDiv(RAY, params.collateralPriceInRay, Math.Rounding.Ceil);
        uint256 collateral_denom = F - uint256(params.targetLtvInWad);
        collateralAmount = collateral_num.mulDiv(WAD, collateral_denom, Math.Rounding.Ceil);
        debtAmount = _convertXToY(F, collateralAmount, params.collateralPriceInRay);
    }

    function allocFloatingAndLoopRepay(FlashLoanParams memory params, uint64 premiumInWad)
        internal
        pure
        returns (uint256 collateralAmount, uint256 debtAmount)
    {
        uint256 OneOverF = WAD.mulDiv(WAD, _F(premiumInWad, params.maxSlippageInWad), Math.Rounding.Ceil);

        uint256 debtAmountInCollateral = params.debtAmount.mulDiv(RAY, params.collateralPriceInRay, Math.Rounding.Ceil);
        uint256 adjustedCollateral = uint256(params.targetLtvInWad).mulDiv(params.collateralAmount, WAD)
            + OneOverF.mulDiv(params.floatingAmount, WAD);
        uint256 collateral_num =
            (adjustedCollateral >= debtAmountInCollateral) ? 0 : debtAmountInCollateral - adjustedCollateral;

        uint256 collateral_denom = OneOverF - uint256(params.targetLtvInWad);
        collateralAmount = collateral_num.mulDiv(WAD, collateral_denom, Math.Rounding.Ceil);

        debtAmount = _convertXToY(OneOverF, collateralAmount + params.floatingAmount, params.collateralPriceInRay);
    }

    function allocFloatingAndLoopSupply(FlashLoanParams memory params, uint64 premiumInWad)
        internal
        pure
        returns (uint256 collateralAmount, uint256 debtAmount)
    {
        uint256 F = _F(premiumInWad, params.maxSlippageInWad);
        uint256 collateral_num = uint256(params.targetLtvInWad)
            .mulDiv(params.collateralAmount + params.floatingAmount, WAD)
        - params.debtAmount.mulDiv(RAY, params.collateralPriceInRay, Math.Rounding.Ceil);
        uint256 collateral_denom = F - uint256(params.targetLtvInWad);
        collateralAmount = collateral_num.mulDiv(WAD, collateral_denom, Math.Rounding.Ceil);
        debtAmount = _convertXToY(F, collateralAmount, params.collateralPriceInRay);
    }

    //----------------------------------------------------------
    // Bounds and Max Functions
    //----------------------------------------------------------

    function requiredWithdrawToHitTargetLtv(FlashLoanParams memory params, uint64 targetLtvInWad)
        internal
        pure
        returns (uint256)
    {
        uint256 newCollateral =
            params.debtAmount.mulDiv(RAY, params.collateralPriceInRay).mulDiv(WAD, uint256(targetLtvInWad));
        if (newCollateral >= params.collateralAmount) return 0;
        return params.collateralAmount - newCollateral;
    }

    // formula is
    // 1/lambda_new = 1/lambda_old - withdrawAmount * collateralPriceInRay / debtAmount
    // Returns the new LTV after withdrawal and a flag indicating if the LTV is invalid/infinite.
    // The LTV is invalid when the withdrawal amount equals or exceeds the collateral amount (accounting for rounding).
    // This occurs when: withdrawAmount * collateralPriceInRay * currentLtvInWad >= debtAmount * RAY
    // Due to rounding in mulDiv operations, this condition may be reached slightly before the exact collateral amount.
    function newLtvAfterWithdrawInWad(
        uint256 withdrawAmount,
        uint64 currentLtvInWad_,
        uint256 debtAmount,
        uint256 collateralPriceInRay
    ) internal pure returns (NewLtvResult memory) {
        if (debtAmount == 0) return NewLtvResult({ltvInWad: 0, isInvalid: false});
        uint256 OneOverLtvOld = WAD.mulDiv(WAD, uint256(currentLtvInWad_));
        uint256 OneOverLtvExtra = withdrawAmount.mulDiv(collateralPriceInRay, RAY).mulDiv(WAD, debtAmount);
        if (OneOverLtvExtra >= OneOverLtvOld) {
            return NewLtvResult({ltvInWad: type(uint64).max, isInvalid: true});
        }
        uint256 newLtvInWad = WAD.mulDiv(WAD, OneOverLtvOld - OneOverLtvExtra);
        if (newLtvInWad > type(uint64).max) {
            return NewLtvResult({ltvInWad: type(uint64).max, isInvalid: true});
        }
        return NewLtvResult({ltvInWad: newLtvInWad.toUint64(), isInvalid: false});
    }

    function targetLtvUpperBound(FlashLoanParams memory params, uint64 premiumInWad) internal pure returns (uint64) {
        return WAD.mulDiv(WAD, _F(premiumInWad, params.maxSlippageInWad)).toUint64();
    }

    function allocationLowerBound(FlashLoanParams memory params, uint64 premiumInWad) internal pure returns (uint256) {
        uint256 targetLtvInWad = uint256(params.targetLtvInWad);
        uint256 debtAmountInCollateral = params.debtAmount.mulDiv(RAY, params.collateralPriceInRay, Math.Rounding.Ceil);
        uint256 collateralTimesTargetLtv = params.collateralAmount.mulDiv(targetLtvInWad, WAD);
        if (collateralTimesTargetLtv >= debtAmountInCollateral) return 0;
        return _F(premiumInWad, params.maxSlippageInWad).mulDiv(debtAmountInCollateral - collateralTimesTargetLtv, WAD);
    }

    function allocationUpperBound(FlashLoanParams memory params) internal pure returns (uint256) {
        uint256 targetLtvInWad = uint256(params.targetLtvInWad);
        uint256 currentLtvInWad_ = currentLtvInWad(params);
        if (targetLtvInWad == 0) return type(uint256).max;
        if (currentLtvInWad_ <= targetLtvInWad) return 0;
        return params.collateralAmount.mulDiv(currentLtvInWad_ - targetLtvInWad, targetLtvInWad);
    }

    function deallocationBound(FlashLoanParams memory params) internal pure returns (uint256) {
        uint256 targetLtvInWad = uint256(params.targetLtvInWad);
        uint256 currentLtvInWad_ = currentLtvInWad(params);
        if (targetLtvInWad == 0 && currentLtvInWad_ == 0) return params.collateralAmount;
        if (targetLtvInWad < currentLtvInWad_) return 0;
        return params.collateralAmount.mulDiv(targetLtvInWad - currentLtvInWad_, targetLtvInWad);
    }

    // Note: The critical deallocation is equal to the position value if and only if the flash amount is equal to the debt amount.
    // The critical deallocation is larger than the position value if and only if the flash amount requested is larger than the debt amount.
    // The critical deallocation is smaller than the position value if and only if the flash amount requested is smaller than the debt amount.
    // These statements assume that the flash premium amount is non-decreasing with respect to the flash amount.
    function criticalDeallocation(FlashLoanParams memory params, uint64 premiumInWad) internal pure returns (uint256) {
        uint256 criticalDeallocationAmount = _positionValue(
            params.debtAmount,
            params.collateralAmount,
            params.collateralPriceInRay,
            premiumInWad,
            params.maxSlippageInWad
        );
        return criticalDeallocationAmount;
    }

    function maxWithdrawableGivenLiquidityDepth(
        FlashLoanParams memory params,
        TokenPair memory tokenPair,
        address flashModule,
        uint256 collateralLiquidityDepth,
        uint256 collateralEpsilon
    ) internal view returns (uint256) {
        if (params.targetLtvInWad == 0) {
            if (params.debtAmount > IFlashModule(flashModule).depthOfFlashLiquidityExact(tokenPair.borrowToken)) {
                return 0;
            }
            uint256 effectiveCollateralValueOfDebt = _effectiveCollateralValueOfDebt(
                params.debtAmount,
                params.collateralPriceInRay,
                params.debtAmount > 0
                    ? IFlashModule(flashModule).flashPremiumQuoteInWad(tokenPair.borrowToken, params.debtAmount)
                    : 0,
                params.maxSlippageInWad
            );
            uint256 cappedCollateralDepth = Math.min(collateralLiquidityDepth, params.collateralAmount);
            // if the effective value of debt is larger than the capped collateral depth, the position is not unwindable and so also the additional floating amount is not withdrawable.
            if (effectiveCollateralValueOfDebt > cappedCollateralDepth) return 0;
            // alternatively we add the additional floating amount to the difference.
            return params.floatingAmount + cappedCollateralDepth - effectiveCollateralValueOfDebt;
        }
        // next we need to check whether the maximum withdrawable amount allowed to reach the non-zero target ltv warrants a supply loop or a repay loop.
        uint256 deallocationBound_ = deallocationBound(params);

        uint256 adjustedEpsilon = collateralEpsilon.mulDiv(
            _F(
                IFlashModule(flashModule).flashPremiumQuoteInWad(tokenPair.collateralToken, collateralEpsilon),
                params.maxSlippageInWad
            ) - params.targetLtvInWad,
            params.targetLtvInWad
        );
        bool loopRepay = false;
        if (deallocationBound_ <= adjustedEpsilon) {
            if (collateralLiquidityDepth <= deallocationBound_) return 0;
            loopRepay = true;
        } else {
            // deallocationBound_ > adjustedEpsilon
            if (collateralLiquidityDepth < deallocationBound_) {
                // loop supply (target ltv above current one)
                // dont require to withdraw from the lender, can just enter a minimal winding with the collateral liquidity of the flash provider permits
                // we may wedraw up to
                if (IFlashModule(flashModule).depthOfFlashLiquidityExact(tokenPair.collateralToken) < collateralEpsilon)
                {
                    return 0;
                }
                return params.floatingAmount + deallocationBound_ - adjustedEpsilon;
            } else if (collateralLiquidityDepth == deallocationBound_) {
                // at best/most we can do a plain withdrawal
                // no need to check that collateralLiquidityDepth <= collateralAmount, because deallocationBound_ < collateralAmount
                return params.floatingAmount + collateralLiquidityDepth;
            } else {
                // deallocationBound_ < collateralLiquidityDepth
                loopRepay = true;
            }
        }
        // at this point it must have either returned or loopRepay is true
        if (!loopRepay) return 0;

        uint64 flashPremiumInWad =
            IFlashModule(flashModule).flashPremiumQuoteInWad(tokenPair.borrowToken, params.debtAmount);
        uint256 lenderWithdrawalCap = maxLenderWithdrawalCapacity(params, collateralLiquidityDepth, flashPremiumInWad);
        uint256 flashProviderWithdrawalCap = maxFlashProviderWithdrawalCapacityForBorrow(
            params, IFlashModule(flashModule).depthOfFlashLiquidityExact(tokenPair.borrowToken), flashPremiumInWad
        );
        return params.floatingAmount + Math.min(lenderWithdrawalCap, flashProviderWithdrawalCap);
    }

    function maxLenderWithdrawalCapacity(
        FlashLoanParams memory params,
        uint256 lenderCollateralLiquidityDepth,
        uint64 flashPremiumInWad
    ) internal pure returns (uint256) {
        // if lendlerCollateralLiquidityDepth >= collateralAmount, then its the postionValue;
        if (lenderCollateralLiquidityDepth >= params.collateralAmount) {
            return _positionValue(
                params.debtAmount,
                params.collateralAmount,
                params.collateralPriceInRay,
                flashPremiumInWad,
                params.maxSlippageInWad
            );
        }
        // this is going to be queried when target ltv is smaller than current ltv,
        // but it should also work in the other case, so we make a distinction
        uint256 F = _F(flashPremiumInWad, params.maxSlippageInWad);
        uint256 FtimesTargetLtv = F.mulDiv(params.targetLtvInWad, WAD);
        if (FtimesTargetLtv >= WAD) return 0;
        uint256 cappedLenderLiquidationDepth = Math.min(lenderCollateralLiquidityDepth, params.collateralAmount);
        uint256 adjustedLiquidityDepth = cappedLenderLiquidationDepth.mulDiv(WAD - FtimesTargetLtv, WAD)
            + params.collateralAmount.mulDiv(FtimesTargetLtv, WAD);
        uint256 debt = params.collateralAmount.mulDiv(F, WAD).mulDiv(currentLtvInWad(params), WAD);
        if (debt >= adjustedLiquidityDepth) return 0;
        return adjustedLiquidityDepth - debt;
    }

    function maxFlashProviderWithdrawalCapacityForBorrow(
        FlashLoanParams memory params,
        uint256 flashProviderBorrowLiquidityDepth,
        uint64 flashPremiumInWad
    ) internal pure returns (uint256 maxCap) {
        if (params.targetLtvInWad == 0) {
            if (params.debtAmount > flashProviderBorrowLiquidityDepth) return 0;
            return flashProviderBorrowLiquidityDepth;
        }
        return _maxFlashProviderWithdrawalCapacityForBorrow(
            params, flashProviderBorrowLiquidityDepth, _F(flashPremiumInWad, params.maxSlippageInWad)
        );
    }

    function _maxFlashProviderWithdrawalCapacityForBorrow(
        FlashLoanParams memory params,
        uint256 flashProviderBorrowLiquidityDepth,
        uint256 factor
    ) internal pure returns (uint256 maxCap) {
        uint256 fTimesTargetLtv = factor.mulDiv(params.targetLtvInWad, WAD);
        if (fTimesTargetLtv >= WAD) return 0;
        uint256 adjustedLiquidityDepth = flashProviderBorrowLiquidityDepth.mulDiv(WAD - fTimesTargetLtv, WAD)
            .mulDiv(RAY, params.collateralPriceInRay, Math.Rounding.Ceil)
            .mulDiv(WAD, currentLtvInWad(params)) + params.collateralAmount;
        uint256 adjustedCollateralAmount =
            params.collateralAmount.mulDiv(currentLtvInWad(params), params.targetLtvInWad);
        maxCap = (adjustedCollateralAmount >= adjustedLiquidityDepth)
            ? 0
            : adjustedLiquidityDepth - adjustedCollateralAmount;
    }

    //----------------------------------------------------------
    // Internal Helper functions
    //----------------------------------------------------------

    function _getEquity(uint256 collateral, uint256 debt, uint256 collateralPriceInRay)
        internal
        pure
        returns (uint256)
    {
        return collateral - debt.mulDiv(RAY, collateralPriceInRay, Math.Rounding.Ceil);
    }

    function _currentLtvInWad(uint256 collateralAmount, uint256 debtAmount, uint256 collateralPriceInRay)
        internal
        pure
        returns (uint64)
    {
        return Math.min(
                debtAmount.mulDiv(RAY, collateralPriceInRay, Math.Rounding.Ceil)
                    .mulDiv(WAD, collateralAmount, Math.Rounding.Ceil),
                type(uint64).max
            )
            .toUint64();
    }

    function _effectiveCollateralValueOfDebt(
        uint256 debtAmount,
        uint256 collateralPriceInRay,
        uint64 premiumForFlashingDebtAmountInWad,
        uint64 maxSlippageInWad
    ) internal pure returns (uint256) {
        uint256 F = _F(premiumForFlashingDebtAmountInWad, maxSlippageInWad);
        return debtAmount.mulDiv(F, WAD).mulDiv(RAY, collateralPriceInRay, Math.Rounding.Ceil);
    }

    //----------------------------------------------------------
    // Auxiliary Utility Functions
    //----------------------------------------------------------

    function _F(uint64 premiumInWad, uint64 maxSlippageInWad) internal pure returns (uint256) {
        return WAD.mulDiv(WAD + uint256(premiumInWad), WAD - uint256(maxSlippageInWad));
    }

    function _convertXToY(uint256 factor, uint256 principalAmount, uint256 collateralPriceInRay)
        internal
        pure
        returns (uint256)
    {
        return principalAmount.mulDiv(collateralPriceInRay, RAY).mulDiv(factor, WAD);
    }

    // strictly _wadify should not be used when value/denominator is greater than type(uint64).max
    function _wadify(uint256 value, uint256 denominator) internal pure returns (uint64) {
        return Math.min(value.mulDiv(WAD, denominator + 1), type(uint64).max).toUint64();
    }

    function _dewadify(uint64 value, uint256 denominator) internal pure returns (uint256) {
        if (value == type(uint64).max) return type(uint256).max;
        return uint256(value).mulDiv(denominator + 1, WAD);
    }
}
