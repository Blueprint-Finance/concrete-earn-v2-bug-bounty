// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {FlashLoanParams, LeverageData, TokenPair} from "../../interface/ILoopingPrimitive.sol";
import {
    PreviewOperationParams,
    LenderModuleState,
    IBaseLoopingStrategy
} from "../../interface/IBaseLoopingStrategy.sol";
import {ILenderModule} from "../../interface/ILenderModule.sol";
import {ILenderStaging} from "../../interface/ILenderStaging.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {LoopingPrimitiveLib} from "./LoopingPrimitiveLib.sol";
import {LoopModalityLib, LoopModality} from "./LoopModalityLib.sol";
import {ErrorInfoLib, ErrorInfo} from "../ErrorInfoLib.sol";
import {BaseLoopingStrategyStorageLib as BLSSLib} from "./BaseLoopingStrategyStorageLib.sol";
import {BaseStrategyStorageLib} from "../BaseStrategyStorageLib.sol";

/**
 * @title BaseLoopingHelperLib
 * @notice External library holding the heavy computation paths extracted from
 *         BaseLoopingStrategy. Because these functions are external, the library is deployed
 *         as a separate contract and called via DELEGATECALL, keeping their bytecode out of
 *         the strategy's size budget.
 * @dev All storage reads inside these functions operate on the calling strategy's storage
 *      because they are invoked via DELEGATECALL.
 */
library BaseLoopingHelperLib {
    using LoopingPrimitiveLib for FlashLoanParams;
    using ErrorInfoLib for ErrorInfo;
    using LoopModalityLib for LoopModality;
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Preview helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Computes the preview result for the non-looping path.
     * @dev Pure: the caller pre-fetches collateralAmount; no storage reads are needed here.
     * @param collateralAmount Current collateral amount from the lender module.
     * @param po Preview operation parameters.
     */
    function previewOperationNonLooping(uint256 collateralAmount, PreviewOperationParams memory po)
        external
        pure
        returns (LoopModality loopModality, LeverageData memory leverageData, uint256 oldEquity)
    {
        loopModality = LoopModalityLib.init(false).setLoopSupply(po.isAllocation).setPlainOperation(true)
            .setAllocateFloating(po.isAllocation);
        oldEquity = collateralAmount;
        leverageData.newEquity = collateralAmount;

        if (po.isAllocation) {
            leverageData.newEquity += po.allocOrDeallocAmount;
        } else {
            if (po.allocOrDeallocAmount > leverageData.newEquity) {
                leverageData.errorInfo = leverageData.errorInfo.setError(1, true)
                    .setWadPayload(1, LoopingPrimitiveLib._wadify(leverageData.newEquity, collateralAmount));
                return (loopModality, leverageData, oldEquity);
            }
            leverageData.newEquity -= po.allocOrDeallocAmount;
        }
    }

    /**
     * @notice Computes the looping preview result after _prepareLoopParams has been called.
     * @dev Handles all deallocation edge cases and the final getLeverageModalityAndData call.
     *      When floatingAmount==0 the function reads lender position directly from storage
     *      (safe because this function is invoked via DELEGATECALL from the strategy).
     * @param params Flash loan parameters already populated by _prepareLoopParams.
     * @param tokenPair Collateral/borrow token pair.
     * @param loopModality Current loop modality.
     * @param flashModule_ Address of the flash module.
     * @param po Preview operation parameters.
     */
    function previewOperationLooping(
        FlashLoanParams memory params,
        TokenPair memory tokenPair,
        LoopModality loopModality,
        address flashModule_,
        PreviewOperationParams memory po
    ) external view returns (LoopModality, LeverageData memory leverageData, uint256 oldEquity) {
        oldEquity =
            LoopingPrimitiveLib._getEquity(params.collateralAmount, params.debtAmount, params.collateralPriceInRay);

        if (!po.isAllocation) {
            // Edge case: floatingAmount==0 means the plain withdraw path is used; the new equity is
            // computed from the live lender position rather than from flash-loan math.
            // Storage reads are valid here because this library is called via DELEGATECALL.
            if (params.floatingAmount == 0) {
                ILenderModule lm = ILenderModule(BLSSLib.fetch().lenderModule);
                tokenPair.borrowToken = BaseStrategyStorageLib.fetch().asset;
                uint256 collateralPriceInRay = lm.collateralPriceInBorrowTokensInRay();
                leverageData.newEquity = LoopingPrimitiveLib._getEquity(
                    lm.getCollateralAmount() - po.allocOrDeallocAmount, lm.getDebtAmount(), collateralPriceInRay
                );
                return (loopModality, leverageData, oldEquity);
            }

            uint256 maxWithdraw_ = LoopingPrimitiveLib.lenderPositionValue(
                flashModule_,
                tokenPair.borrowToken,
                params.collateralAmount,
                params.debtAmount,
                params.collateralPriceInRay,
                po.maxSlippageInWad
            );
            if (maxWithdraw_ < po.allocOrDeallocAmount) {
                uint64 wadPayload = params.collateralAmount > 0
                    ? LoopingPrimitiveLib._wadify(maxWithdraw_, params.collateralAmount)
                    : 0;
                leverageData.errorInfo = leverageData.errorInfo.setError(1, true).setWadPayload(1, wadPayload);
                return (loopModality, leverageData, oldEquity);
            }
        }

        (loopModality, leverageData) = params.getLeverageModalityAndData(flashModule_, tokenPair, loopModality);
        return (loopModality, leverageData, oldEquity);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Lender module setter
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Sets the lender module, revokes approvals from the old one, and grants approvals to the new one.
     * @dev Called via DELEGATECALL from BaseLoopingStrategy._setLenderModule so all storage reads
     *      and writes operate on the strategy's own storage.
     */
    function setLenderModule(address lenderModule_, bool emitEvent) external {
        if (lenderModule_ == address(0)) revert IBaseLoopingStrategy.ZeroLenderModuleAddress();
        BLSSLib.BaseLoopingStorage storage $ = BLSSLib.fetch();
        address currentLenderModule = $.lenderModule;
        if (currentLenderModule != address(0)) _removeApprovalFromUnfundedLenderModule(currentLenderModule);
        LenderModuleState memory newState = _lenderModuleState(lenderModule_);
        if (newState.collateralToken != BaseStrategyStorageLib.fetch().asset) {
            revert IBaseLoopingStrategy.InvalidCollateralToken();
        }
        if (newState.borrowToken == newState.collateralToken || newState.borrowToken == address(0)) {
            revert IBaseLoopingStrategy.InvalidBorrowToken();
        }
        IERC20(newState.collateralToken).forceApprove(lenderModule_, type(uint256).max);
        IERC20(newState.borrowToken).forceApprove(lenderModule_, type(uint256).max);
        $.lenderModule = lenderModule_;
        if (emitEvent) emit IBaseLoopingStrategy.LenderModuleSet(currentLenderModule, lenderModule_);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers (inlined into the library's own bytecode)
    // ─────────────────────────────────────────────────────────────────────────

    function _lenderModuleState(address lenderModule_) internal view returns (LenderModuleState memory state) {
        state.collateralToken = ILenderModule(lenderModule_).collateralToken();
        state.borrowToken = ILenderModule(lenderModule_).borrowToken();
        (state.collateralAmount, state.debtAmount) = ILenderModule(lenderModule_).getPosition();
        state.collateralBalance = ILenderStaging(lenderModule_).staged();
        state.hasFunds = state.collateralAmount != 0 || state.debtAmount != 0 || state.collateralBalance != 0;
    }

    function _removeApprovalFromUnfundedLenderModule(address lenderModule_) internal {
        LenderModuleState memory currentState = _lenderModuleState(lenderModule_);
        if (currentState.hasFunds) {
            revert IBaseLoopingStrategy.PreviousLenderModuleHasFunds(
                currentState.collateralAmount, currentState.debtAmount, currentState.collateralBalance
            );
        }
        IERC20(currentState.collateralToken).forceApprove(lenderModule_, 0);
        IERC20(currentState.borrowToken).forceApprove(lenderModule_, 0);
    }
}
