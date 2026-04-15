// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

/**
 * @title BaseLoopingStrategy
 * @notice Abstract base contract for looping strategies that enables leveraged positions
 *         through flash loans and debt management. Provides functionality for allocation,
 *         deallocation, leverage adjustment, and position management with configurable LTV bounds.
 *
 * @author Blueprint Finance
 * @custom:protocol Concrete Earn V2
 * @custom:oz-upgrades Use OZ Upgradeable patterns and eip7201 storage layout
 * @custom:source on request
 * @custom:audits on request
 * @custom:license AGPL-3.0
 */

// ─────────────────────────────────────────────────────────────────────────────
// External dependencies
// ─────────────────────────────────────────────────────────────────────────────
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Protocol-facing interfaces
// ─────────────────────────────────────────────────────────────────────────────
import {IBaseLoopingStrategy} from "../interface/IBaseLoopingStrategy.sol";
import {ILenderModule} from "../interface/ILenderModule.sol";
import {ILenderStaging} from "../interface/ILenderStaging.sol";
import {IFlashModule} from "../interface/IFlashModule.sol";
import {
    FlashLoanParams,
    LeverageCondition,
    LtvBounds,
    LenderPosition,
    LeverageData,
    TokenPair,
    NewLtvResult
} from "../interface/ILoopingPrimitive.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Internal contracts
// ─────────────────────────────────────────────────────────────────────────────
import {LoopingPrimitive} from "./LoopingPrimitive.sol";
import {BaseStrategy} from "./BaseStrategy.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Internal libraries
// ─────────────────────────────────────────────────────────────────────────────
import {LoopConfig, LoopConfigLib} from "../lib/Looping/LoopConfigLib.sol";
import {LoopModalityLib, LoopModality, LeverageOperation} from "../lib/Looping/LoopModalityLib.sol";
import {LoopingPrimitiveLib} from "../lib/Looping/LoopingPrimitiveLib.sol";
import {ErrorInfoLib, ErrorInfo} from "../lib/ErrorInfoLib.sol";
import {PeripheryRolesLib} from "../lib/PeripheryRolesLib.sol";
import {BaseStrategyStorageLib} from "../lib/BaseStrategyStorageLib.sol";
import {WAD} from "../lib/Constants.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Storage layout libraries
// ─────────────────────────────────────────────────────────────────────────────
import {BaseLoopingStrategyStorageLib as BLSSLib} from "../lib/Looping/BaseLoopingStrategyStorageLib.sol";
import {BaseLoopingHelperLib} from "../lib/Looping/BaseLoopingHelperLib.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Types from interfaces
// ─────────────────────────────────────────────────────────────────────────────
import {
    PreviewOperationFlags,
    PreviewOperationParams,
    PreviewOperationResult
} from "../interface/IBaseLoopingStrategy.sol";

abstract contract BaseLoopingStrategy is LoopingPrimitive, BaseStrategy, IBaseLoopingStrategy {
    using LoopConfigLib for LoopConfig;
    using LoopingPrimitiveLib for FlashLoanParams;
    using ErrorInfoLib for ErrorInfo;
    using LoopModalityLib for LoopModality;
    using Math for uint256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    //--------------------------------------------------------
    // Modifiers
    //--------------------------------------------------------

    modifier onlyAdminOrOperatorWhenNotPaused() {
        bool paused_ = paused();
        bool isAdmin = hasRole(PeripheryRolesLib.STRATEGY_ADMIN, msg.sender);
        bool isOperatorOrAdmin = hasRole(PeripheryRolesLib.OPERATOR_ROLE, msg.sender) || isAdmin;
        if (paused_ && !isAdmin) revert EnforcedPause();
        if (!paused_ && !isOperatorOrAdmin) {
            revert AccessControlUnauthorizedAccount(msg.sender, PeripheryRolesLib.OPERATOR_ROLE);
        }
        _;
    }

    //--------------------------------------------------------
    // Allocation and Deallocation
    //--------------------------------------------------------

    /**
     * @dev Abstract virtual function to allocate funds to the position
     * @param data The data containing the amount to allocate and protocol specific data
     * @return The actual amount allocated
     */
    function _allocateToPosition(bytes calldata data) internal virtual override returns (uint256) {
        (uint256 amountToAllocate) = abi.decode(data, (uint256));

        BLSSLib.BaseLoopingStorage storage $ = BLSSLib.fetch();
        LoopConfig loopConfig = $.loopConfig;

        // if looping is not enabled, supply the funds to the position
        if (!loopConfig.isLooping()) {
            _supply(BaseStrategyStorageLib.fetch().asset, amountToAllocate);
            return amountToAllocate;
        }

        (
            LoopModality loopModality,
            FlashLoanParams memory params,
            LtvBounds memory ltvBounds,
            TokenPair memory tokenPair
        ) = _prepareLoopParams(
            amountToAllocate,
            loopConfig,
            $.maxSlippageInWad,
            0,
            PreviewOperationFlags({isAllocation: true, isUserWithdraw: false})
        );

        _leverage(params, loopModality, tokenPair);

        _checkAndStage(loopModality, amountToAllocate, tokenPair, ltvBounds);

        return amountToAllocate;
    }

    /**
     * @dev Abstract virtual function to deallocate funds from the position
     * @param data The data containing the amount to deallocate and protocol specific data
     * @return The actual amount deallocated
     */
    function _deallocateFromPosition(bytes calldata data) internal virtual override returns (uint256) {
        uint256 amountToDeallocate = abi.decode(data, (uint256));

        if (amountToDeallocate == type(uint256).max) {
            // use position value
            amountToDeallocate = _previewPosition();
        }

        // load variables from storage and calldata
        BLSSLib.BaseLoopingStorage storage $ = BLSSLib.fetch();
        LoopConfig loopConfig = $.loopConfig;

        if (!loopConfig.isLooping()) {
            _withdraw(BaseStrategyStorageLib.fetch().asset, amountToDeallocate);
            return amountToDeallocate;
        }

        (
            LoopModality loopModality,
            FlashLoanParams memory params,
            LtvBounds memory ltvBounds,
            TokenPair memory tokenPair
        ) = _prepareLoopParams(
            amountToDeallocate,
            loopConfig,
            $.maxSlippageInWad,
            0,
            PreviewOperationFlags({isAllocation: false, isUserWithdraw: false})
        );

        if (loopModality.maxWithdraw()) _setTargetLtvAndDeviation(0, 0, true);

        _leverage(params, loopModality, tokenPair);

        _checkAndStage(loopModality, amountToDeallocate, tokenPair, ltvBounds);

        return amountToDeallocate;
    }

    //--------------------------------------------------------
    // Withdraw Functions
    //--------------------------------------------------------

    function _withdrawFromPosition(uint256 assets) internal virtual override returns (uint256) {
        // do a simple withdraw, but if it exceeds the max LTV then
        // get config
        BLSSLib.BaseLoopingStorage storage $ = BLSSLib.fetch();
        LoopConfig loopConfig = $.loopConfig;
        if (!loopConfig.isLooping()) {
            _withdraw(BaseStrategyStorageLib.fetch().asset, assets);
            return assets;
        }

        (
            LoopModality loopModality,
            FlashLoanParams memory params,
            LtvBounds memory ltvBounds,
            TokenPair memory tokenPair
        ) = _prepareLoopParams(
            assets,
            loopConfig,
            $.maxSlippageInWad,
            0,
            PreviewOperationFlags({isAllocation: false, isUserWithdraw: true})
        );

        if (loopModality.maxWithdraw()) _setTargetLtvAndDeviation(0, 0, true);

        // in order to avoid attacks that trigger the loop (=> incur loss on vault) with small atomic withdrawal requests,
        // there is an option for withdrawal if it stays within the range of allowed ltv.
        if (loopModality.plainOperation()) _withdraw(tokenPair.collateralToken, params.floatingAmount);
        else _leverage(params, loopModality, tokenPair);

        _checkAndStage(loopModality, assets, tokenPair, ltvBounds);
        return assets;
    }

    //--------------------------------------------------------
    // Releveraging Functions
    //--------------------------------------------------------

    // permissionless adjustment of the leverage back to the target parameters.
    function adjustLeverage() external virtual override whenNotPaused {
        BLSSLib.BaseLoopingStorage storage $ = BLSSLib.fetch();
        LoopConfig loopConfig = $.loopConfig;
        if (!loopConfig.isLooping()) revert LoopingIsDisabled();
        if (loopConfig.permissioned()) revert PermissionedLtvAdjustment();
        LtvBounds memory ltvBounds = _getLtvBounds(true);
        uint64 currentLtv = _lenderModule().getCurrentLtvInWad();
        LeverageCondition leverageCondition = _checkLeverageCondition(ltvBounds, currentLtv);
        // Note: We skip checking LeverageCondition.Disabled here because looping is already verified
        // as enabled above. The Disabled condition in _checkLeverageCondition() only checks looping state,
        // which we've already validated.
        if (leverageCondition == LeverageCondition.WithinBounds) {
            revert LtvWithinBounds(currentLtv, ltvBounds.target, ltvBounds.deviation);
        }
        _adjustLeverage(loopConfig, 0, $.maxSlippageInWad);
    }

    // permissioned adjustment of the leverage, with custom target ltv and slippage parameters.
    function adjustLeverage(uint64 maxSlippageInWad, uint64 targetLtvInWad, bool setNewTargetLtv)
        external
        virtual
        override
        onlyAdminOrOperatorWhenNotPaused
    {
        BLSSLib.BaseLoopingStorage storage $ = BLSSLib.fetch();
        LoopConfig loopConfig = $.loopConfig;
        if (!loopConfig.isLooping()) revert LoopingIsDisabled();
        // No need to check ltv bounds (especially not whether ltv > 1.0) because thats handled in the _adjustLeverage function
        if (setNewTargetLtv) {
            _setTargetLtvAndDeviation(targetLtvInWad, $.ltvAdditiveDeviationInWad, true);
            // sets new target ltv and by passing in the value of 0, it will use the target ltv from storage
            _adjustLeverage(loopConfig, 0, maxSlippageInWad);
        } else {
            uint64 maxLtvInWad = _lenderModule().getMaxLtvInWad();
            if (targetLtvInWad > maxLtvInWad) {
                revert TargetLtvPlusDeviationAboveMaxLtv(targetLtvInWad, $.ltvAdditiveDeviationInWad, maxLtvInWad);
            }
            _adjustLeverage(loopConfig, targetLtvInWad + 1, maxSlippageInWad);
        }
    }

    function _adjustLeverage(LoopConfig loopConfig, uint64 targetLtvPlusOneInWad, uint64 maxSlippageInWad)
        internal
        virtual
    {
        // get target ltv from storage
        (
            LoopModality loopModality,
            FlashLoanParams memory params,
            LtvBounds memory ltvBounds,
            TokenPair memory tokenPair
        ) = _prepareLoopParams(
            0,
            loopConfig,
            maxSlippageInWad,
            targetLtvPlusOneInWad,
            PreviewOperationFlags({isAllocation: true, isUserWithdraw: false})
        );

        _leverage(params, loopModality, tokenPair);

        _checkAndStage(loopModality, 0, tokenPair, ltvBounds);
    }

    //--------------------------------------------------------
    // Lender Operations
    //--------------------------------------------------------

    function _supply(
        address, // collateralToken
        uint256 amount
    )
        internal
        override
    {
        _lenderModule().supply(amount);
    }

    function _withdraw(
        address, // collateralToken
        uint256 amount
    )
        internal
        override
    {
        _lenderModule().withdraw(amount);
    }

    function _repay(
        address, // borrowToken
        uint256 amount
    )
        internal
        override
    {
        _lenderModule().repay(amount);
    }

    function _borrow(
        address, // borrowToken
        uint256 amount
    )
        internal
        override
    {
        _lenderModule().borrow(amount);
    }

    //--------------------------------------------------------
    // Preview Functions Public
    //--------------------------------------------------------

    function previewOperation(
        uint256 allocOrDeallocAmount,
        bool isAllocation,
        uint64 targetLtvInWad,
        uint64 maxSlippageInWad
    )
        public
        view
        returns (
            PreviewOperationResult memory result,
            bool ltvUpperBoundReached,
            bool deallocationHigherThanEquity,
            bool insufficientFlashLiquidity
        )
    {
        if (targetLtvInWad > WAD) {
            return (result, true, false, false);
        }
        LoopModality loopModality;
        LeverageData memory leverageData;
        uint256 oldEquity;
        (loopModality, leverageData, oldEquity) = _previewOperation(
            PreviewOperationParams(allocOrDeallocAmount, isAllocation, maxSlippageInWad, targetLtvInWad)
        );

        // Get staged liquidity from lender module
        uint256 stagedLiquidity = ILenderStaging(BLSSLib.fetch().lenderModule).staged();

        // Calculate equities including staged liquidity
        // Note: oldEquity and leverageData.newEquity do NOT include current staged liquidity,
        // so we add it here to get the full position equity
        uint256 positionEquityBeforeOperation = oldEquity + stagedLiquidity;
        uint256 positionEquityAfterOperation = leverageData.newEquity + stagedLiquidity;

        // Calculate maximum loss: positive = loss, negative = gain
        // For allocation: if no loss, equityAfter = equityBefore + allocAmount, so loss = 0
        // For deallocation: if no loss, equityAfter = equityBefore - deallocAmount, so loss = 0
        // We flip the sign so that losses are positive and gains are negative
        int256 maximumLoss;
        if (isAllocation) {
            maximumLoss = int256(positionEquityBeforeOperation) + int256(allocOrDeallocAmount)
                - int256(positionEquityAfterOperation);
        } else {
            maximumLoss = int256(positionEquityBeforeOperation) - int256(allocOrDeallocAmount)
                - int256(positionEquityAfterOperation);
        }

        // Build result struct
        result = PreviewOperationResult({
            flashAmount: leverageData.flashAmount,
            pairedTokenAmount: leverageData.pairedTokenAmount,
            floatingAmount: leverageData.floatingAmount,
            collateralDiff: leverageData.collateralDiff,
            debtDiff: leverageData.debtDiff,
            positionEquityBeforeOperation: positionEquityBeforeOperation,
            positionEquityAfterOperation: positionEquityAfterOperation,
            maximumLoss: maximumLoss,
            flashPremiumQuoteInWad: leverageData.flashPremiumQuoteInWad,
            operation: leverageData.errorInfo.hasError() ? LeverageOperation.None : loopModality.leverageOperation()
        });

        // Set error flags
        ErrorInfo errorInfo = leverageData.errorInfo;
        ltvUpperBoundReached = errorInfo.hasError(0);
        deallocationHigherThanEquity = errorInfo.hasError(1);
        insufficientFlashLiquidity = errorInfo.hasError(2);
    }

    function checkLeverageCondition() external view virtual override returns (bool) {
        LeverageCondition leverageCondition =
            _checkLeverageCondition(_getLtvBounds(true), _lenderModule().getCurrentLtvInWad());
        return leverageCondition != LeverageCondition.WithinBounds && leverageCondition != LeverageCondition.Disabled;
    }

    function maxWithdraw() public view virtual override returns (uint256) {
        uint256 maxWithdrawLimit = BaseStrategyStorageLib.fetch().maxWithdraw;
        if (maxWithdrawLimit == 0) return 0;
        BLSSLib.BaseLoopingStorage storage $ = BLSSLib.fetch();
        return Math.min(maxWithdrawLimit, _getMaxWithdraw($.targetLtvInWad, $.maxSlippageInWad, false));
    }

    function maxDeallocate(uint64 targetLtvInWad, uint64 maxSlippageInWad)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return _getMaxWithdraw(targetLtvInWad, maxSlippageInWad, true);
    }

    //--------------------------------------------------------
    // Admin Interventions
    //--------------------------------------------------------

    function rescueFunds(address token, uint256 amount)
        external
        virtual
        override
        onlyRole(PeripheryRolesLib.STRATEGY_ADMIN)
    {
        address asset = BaseStrategyStorageLib.fetch().asset;
        if (token == asset) revert InvalidAssetForRescue(token);
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    //--------------------------------------------------------
    // Setters
    //--------------------------------------------------------

    function enableLooping(
        address flashModule_,
        address swapModule_,
        uint64 targetLtvInWad,
        uint256 flashCollateralEpsilon_,
        uint64 ltvAdditiveDeviationInWad,
        uint64 maxSlippageInWad,
        bool permissionedLtvAdjustment_
    ) external virtual override onlyRole(PeripheryRolesLib.STRATEGY_ADMIN) {
        // get current loop config
        BLSSLib.BaseLoopingStorage storage $ = BLSSLib.fetch();
        LoopConfig loopConfig = $.loopConfig;
        if (loopConfig.isLooping()) revert LoopingAlreadyEnabled();
        // when enabling looping the targetLtv should not be zero.
        if (targetLtvInWad == 0) revert ZeroTargetLtv();
        if (ltvAdditiveDeviationInWad == 0) revert ZeroLtvAdditiveDeviation();
        if (flashCollateralEpsilon_ == 0) revert ZeroFlashCollateralEpsilon();
        _setFlashModule(flashModule_, false);
        _setSwapModule(swapModule_, false);
        _setMaxSlippage(maxSlippageInWad, false);
        $.loopConfig = LoopConfigLib.pack(true, permissionedLtvAdjustment_);
        $.flashCollateralEpsilon = flashCollateralEpsilon_;
        _setTargetLtvAndDeviation(targetLtvInWad, ltvAdditiveDeviationInWad, false);
        emit LoopingEnabled(
            targetLtvInWad,
            ltvAdditiveDeviationInWad,
            maxSlippageInWad,
            permissionedLtvAdjustment_,
            flashCollateralEpsilon_
        );
    }

    function disableLooping() external virtual override onlyRole(PeripheryRolesLib.STRATEGY_ADMIN) {
        uint256 debtAmount = _lenderModule().getDebtAmount();
        if (debtAmount != 0) revert LenderModuleHasDebt(debtAmount);
        BLSSLib.BaseLoopingStorage storage $ = BLSSLib.fetch();
        $.loopConfig = $.loopConfig.setIsLooping(false);
        emit LoopingDisabled();
    }

    function setTargetLtvAndDeviation(uint64 targetLtvInWad, uint64 ltvAdditiveDeviationInWad)
        external
        virtual
        override
        onlyRole(PeripheryRolesLib.STRATEGY_ADMIN)
    {
        _setTargetLtvAndDeviation(targetLtvInWad, ltvAdditiveDeviationInWad, true);
    }

    function setMaxSlippage(uint64 maxSlippageInWad)
        external
        virtual
        override
        onlyRole(PeripheryRolesLib.STRATEGY_ADMIN)
    {
        _setMaxSlippage(maxSlippageInWad, true);
    }

    function permissionedLtvAdjustment(bool permissionedLtvAdjustment_)
        external
        virtual
        override
        onlyRole(PeripheryRolesLib.STRATEGY_ADMIN)
    {
        BLSSLib.BaseLoopingStorage storage $ = BLSSLib.fetch();
        $.loopConfig = $.loopConfig.setPermissioned(permissionedLtvAdjustment_);
        emit PermissionedLtvAdjustmentUpdated(permissionedLtvAdjustment_);
    }

    function setFlashModule(address flashModule_) external virtual override onlyRole(PeripheryRolesLib.STRATEGY_ADMIN) {
        _setFlashModule(flashModule_, true);
    }

    function setSwapModule(address swapModule_) external virtual override onlyRole(PeripheryRolesLib.STRATEGY_ADMIN) {
        _setSwapModule(swapModule_, true);
    }

    function setLenderModule(address lenderModule_)
        external
        virtual
        override
        onlyRole(PeripheryRolesLib.STRATEGY_ADMIN)
    {
        BaseLoopingHelperLib.setLenderModule(lenderModule_, true);
    }

    //--------------------------------------------------------
    // Getters
    //--------------------------------------------------------

    function lenderModule() public view override returns (address) {
        return BLSSLib.fetch().lenderModule;
    }

    function getLenderPosition() public view returns (LenderPosition memory) {
        return _lenderPosition();
    }

    function getCurrentLtvInWad() public view override returns (uint64) {
        return _lenderModule().getCurrentLtvInWad();
    }

    function loopingIsEnabled() public view override returns (bool) {
        return BLSSLib.fetch().loopConfig.isLooping();
    }

    function getTargetLtvInWad() public view override returns (uint64) {
        return BLSSLib.fetch().targetLtvInWad;
    }

    function getLtvAdditiveDeviationInWad() public view returns (uint64) {
        return BLSSLib.fetch().ltvAdditiveDeviationInWad;
    }

    function getMaxSlippageInWad() public view returns (uint64) {
        return BLSSLib.fetch().maxSlippageInWad;
    }

    // 0x00 and 0x10 (=0 and 2) looping disabled
    // 0x01 (=1) looping enabled, permissionless ltv adjustment
    // 0x11 (=3) looping disable, permissioned ltv adjustment
    function getConfig() public view returns (LoopConfig) {
        return BLSSLib.fetch().loopConfig;
    }

    //--------------------------------------------------------
    // CORE INTERNAL FUNCTIONS
    //--------------------------------------------------------

    function _prepareLoopParams(
        uint256 allocOrDeallocAmount,
        LoopConfig loopConfig,
        uint64 maxSlippageInWad,
        uint64 targetLtvPlusOneInWad,
        PreviewOperationFlags memory flags
    )
        internal
        view
        virtual
        returns (
            LoopModality loopModality,
            FlashLoanParams memory params,
            LtvBounds memory ltvBounds,
            TokenPair memory tokenPair
        )
    {
        // we are previewing and initializing parameters for the case where we are looping, i.e. winding up or down the position.
        ILenderModule lenderModule_ = _lenderModule();
        tokenPair = lenderModule_.getTokenPair();
        loopModality = LoopModalityLib.init(flags.isAllocation);

        // Initialize LTV bounds - same for both allocation and deallocation paths
        ltvBounds = _getLtvBounds(true);
        if (targetLtvPlusOneInWad != 0) {
            ltvBounds.target = targetLtvPlusOneInWad - 1;
        }

        if (flags.isAllocation) {
            // need to service targetLtv and allocOrDeallocAmount
            // this is called either during adjust or during allocate or previewOperation

            (uint256 collateralAmount, uint256 debtAmount) = lenderModule_.getPosition();

            params = FlashLoanParams(
                collateralAmount,
                debtAmount,
                allocOrDeallocAmount,
                lenderModule_.collateralPriceInBorrowTokensInRay(),
                ltvBounds.target,
                maxSlippageInWad
            );

            return (loopModality, params, ltvBounds, tokenPair);
        } else {
            // now we service either deallocate or withdraw by User or preview of the Operation

            params = FlashLoanParams(
                lenderModule_.getCollateralAmount(),
                lenderModule_.getDebtAmount(),
                allocOrDeallocAmount,
                lenderModule_.collateralPriceInBorrowTokensInRay(),
                ltvBounds.target,
                maxSlippageInWad
            );

            if (_adjustLtvBoundsIfWithdrawEntirePosition(params, ltvBounds, tokenPair)) {
                params.targetLtvInWad = ltvBounds.target;
                loopModality = loopModality.setMaxWithdraw(true);
            }

            if (flags.isUserWithdraw) {
                NewLtvResult memory ltvResult = LoopingPrimitiveLib.newLtvAfterWithdrawInWad(
                    allocOrDeallocAmount,
                    lenderModule_.getCurrentLtvInWad(),
                    params.debtAmount,
                    params.collateralPriceInRay
                );
                // If LTV is invalid (withdrawal >= collateral), must use looping operation
                if (!ltvResult.isInvalid && ltvResult.ltvInWad <= ltvBounds.max) {
                    // plain operation
                    loopModality = loopModality.setPlainOperation(true);
                    // will withdraw params.floatingAmount = allocOrDeallocAmount;
                    return (loopModality, params, ltvBounds, tokenPair);
                }
            }

            return (loopModality, params, ltvBounds, tokenPair);
        }
    }

    //--------------------------------------------------------
    // Preview Functions Internal
    //--------------------------------------------------------

    // DOES NOT INCLUDE FLOATING AMOUNT
    function _previewPosition() internal view virtual override returns (uint256 value) {
        ILenderModule lenderModule_ = _lenderModule();
        (uint256 collateralAmount, uint256 debtAmount) = lenderModule_.getPosition();
        BLSSLib.BaseLoopingStorage storage $ = BLSSLib.fetch();
        // check if is looping
        if (!$.loopConfig.isLooping()) {
            // NOTE: It also means that the lender module must not have floating funds!
            return collateralAmount;
        }
        return LoopingPrimitiveLib.lenderPositionValue(
            flashModule(),
            lenderModule_.borrowToken(),
            collateralAmount,
            debtAmount,
            lenderModule_.collateralPriceInBorrowTokensInRay(),
            $.maxSlippageInWad
        );
    }

    // @param allocOrDeallocAmount The amount to allocate or deallocate
    function _previewOperation(PreviewOperationParams memory po)
        internal
        view
        virtual
        returns (LoopModality loopModality, LeverageData memory leverageData, uint256 oldEquity)
    {
        BLSSLib.BaseLoopingStorage storage $ = BLSSLib.fetch();
        if (!$.loopConfig.isLooping()) {
            uint256 collateralAmount = _lenderModule().getCollateralAmount();
            return BaseLoopingHelperLib.previewOperationNonLooping(collateralAmount, po);
        }

        (LoopModality newLoopModality, FlashLoanParams memory params,, TokenPair memory tokenPair) = _prepareLoopParams(
            po.allocOrDeallocAmount,
            $.loopConfig,
            po.maxSlippageInWad,
            po.targetLtvInWad,
            PreviewOperationFlags({isAllocation: po.isAllocation, isUserWithdraw: false})
        );
        loopModality = newLoopModality;

        (loopModality, leverageData, oldEquity) =
            BaseLoopingHelperLib.previewOperationLooping(params, tokenPair, loopModality, flashModule(), po);
    }

    function _getMaxWithdraw(uint64 targetLtvInWad, uint64 slippageInWad, bool isDeallocation)
        internal
        view
        virtual
        returns (uint256)
    {
        // fetch the available lender pool liquidity.
        ILenderModule lenderModule_ = _lenderModule();
        uint256 availablePoolLiquidity = lenderModule_.getAvailablePoolLiquidity();

        // fetch position parameters.
        FlashLoanParams memory params;
        (params.collateralAmount, params.debtAmount) = lenderModule_.getPosition();
        TokenPair memory tokenPair = lenderModule_.getTokenPair();
        params.targetLtvInWad = targetLtvInWad;
        params.maxSlippageInWad = slippageInWad;
        params.floatingAmount = 0;

        BLSSLib.BaseLoopingStorage storage $ = BLSSLib.fetch();
        // if debt is zero, we can withdraw up to the position value.
        if (!$.loopConfig.isLooping()) {
            return Math.min(availablePoolLiquidity, params.collateralAmount);
        }
        params.collateralPriceInRay = lenderModule_.collateralPriceInBorrowTokensInRay();
        if (!isDeallocation) {
            // its a withdrawal.
            LtvBounds memory ltvBounds = _getLtvBounds(true);
            if (availablePoolLiquidity <= LoopingPrimitiveLib.requiredWithdrawToHitTargetLtv(params, ltvBounds.max)) {
                return availablePoolLiquidity;
            }
            // otherwise proceed to the normal handling of max values.
            // update the params if its a max wwl.
        }
        // check the leveraged case in the presence of flash loans and liquidity depth.
        return LoopingPrimitiveLib.maxWithdrawableGivenLiquidityDepth(
            params, tokenPair, flashModule(), availablePoolLiquidity, $.flashCollateralEpsilon
        );
    }

    //--------------------------------------------------------
    // Auxiliary Internal Functions
    //--------------------------------------------------------

    /**
     * @dev Set the target ltv and deviation.
     * @param targetLtvInWad The target ltv in wad.
     * @param ltvAdditiveDeviationInWad The ltv additive deviation in wad.
     * @param emitEvent Whether to emit the event.
     * @dev Can only set target Ltv from zero to non-zero if there is some equity in the position.
     */
    function _setTargetLtvAndDeviation(uint64 targetLtvInWad, uint64 ltvAdditiveDeviationInWad, bool emitEvent)
        internal
        virtual
    {
        uint64 maxLtvInWad = _lenderModule().getMaxLtvInWad();
        if (targetLtvInWad + ltvAdditiveDeviationInWad > maxLtvInWad) {
            revert TargetLtvPlusDeviationAboveMaxLtv(targetLtvInWad, ltvAdditiveDeviationInWad, maxLtvInWad);
        }

        BLSSLib.BaseLoopingStorage storage $ = BLSSLib.fetch();
        $.targetLtvInWad = targetLtvInWad;
        $.ltvAdditiveDeviationInWad = ltvAdditiveDeviationInWad;
        if (emitEvent) emit TargetLtvAndDeviationSet(targetLtvInWad, ltvAdditiveDeviationInWad);
    }

    function _setMaxSlippage(uint64 maxSlippageInWad, bool emitEvent) internal {
        if (maxSlippageInWad == 0) revert ZeroMaxSlippage();
        BLSSLib.fetch().maxSlippageInWad = maxSlippageInWad;
        if (emitEvent) emit MaxSlippageUpdated(maxSlippageInWad);
    }

    function _adjustLtvBoundsIfWithdrawEntirePosition(
        FlashLoanParams memory params,
        LtvBounds memory ltvBounds,
        TokenPair memory tokenPair
    ) internal view virtual returns (bool targetLtvChanged) {
        // if the entire position is being withdrawn, we have to allow for a target ltv of zero.
        // Otherwise the position cannot be entirely withdrawn.
        // get lender position
        if (
            LoopingPrimitiveLib.lenderPositionValue(
                    flashModule(),
                    tokenPair.borrowToken,
                    params.collateralAmount,
                    params.debtAmount,
                    params.collateralPriceInRay,
                    params.maxSlippageInWad
                ) == params.floatingAmount
        ) {
            // shift everything down by the target ltv.
            ltvBounds.max -= ltvBounds.target;
            ltvBounds.target = 0;
            ltvBounds.min = 0;
            ltvBounds.deviation = ltvBounds.max;
            return true;
        }
        return false;
    }

    function _getLtvBounds(bool checkLenderMaxLtv) internal view returns (LtvBounds memory ltvBounds) {
        BLSSLib.BaseLoopingStorage storage $ = BLSSLib.fetch();
        ltvBounds.target = $.targetLtvInWad;
        ltvBounds.deviation = $.ltvAdditiveDeviationInWad;
        ltvBounds.max = ltvBounds.target + ltvBounds.deviation;
        if (checkLenderMaxLtv) {
            uint64 lenderMaxLtv = _lenderModule().getMaxLtvInWad();
            ltvBounds.max = lenderMaxLtv < ltvBounds.max ? lenderMaxLtv : ltvBounds.max;
            // check if the new max ltv (possibly liquidation bound) is smaller than the ltv range of the strategy.
            if (ltvBounds.max < ltvBounds.target + ltvBounds.deviation) {
                // in the unlikely case that the lender has down-adjusted the max ltv, we need to adjust the target ltv to stay within the bounds.
                // at this point we need to advert the danger of hitting liquidation and push the target down.
                ltvBounds.target = ltvBounds.max - ltvBounds.deviation;
                ltvBounds.max = ltvBounds.target + ltvBounds.deviation / 2;
            }
        }
        ltvBounds.min = ltvBounds.target > ltvBounds.deviation ? ltvBounds.target - ltvBounds.deviation : 0;
    }

    function _checkLeverageCondition(LtvBounds memory ltvBounds, uint64 currentLtvInWad)
        internal
        view
        virtual
        returns (LeverageCondition)
    {
        if (!BLSSLib.fetch().loopConfig.isLooping()) return LeverageCondition.Disabled;
        if (currentLtvInWad > ltvBounds.max) return LeverageCondition.AboveUpperLtvBound;
        if (currentLtvInWad < ltvBounds.min) return LeverageCondition.BelowLowerLtvBound;
        return LeverageCondition.WithinBounds;
    }

    function _lenderPosition() internal view returns (LenderPosition memory position) {
        ILenderModule lenderModule_ = _lenderModule();
        position.collateralAmount = lenderModule_.getCollateralAmount();
        position.debtAmount = lenderModule_.getDebtAmount();
        position.floatingAmount = 0;
        position.collateralPriceInRay = lenderModule_.collateralPriceInBorrowTokensInRay();
        position.equity = LoopingPrimitiveLib._getEquity(
            position.collateralAmount, position.debtAmount, position.collateralPriceInRay
        );
    }

    function _lenderModule() internal view returns (ILenderModule) {
        return ILenderModule(BLSSLib.fetch().lenderModule);
    }

    function _checkAndStage(
        LoopModality loopModality,
        uint256 allocOrDeallocAmount,
        TokenPair memory tokenPair,
        LtvBounds memory ltvBounds
    ) internal virtual {
        address lenderModule_ = BLSSLib.fetch().lenderModule;
        uint64 currentLtvInWad = ILenderModule(lenderModule_).getCurrentLtvInWad();
        if (currentLtvInWad < ltvBounds.min) {
            revert LtvBelowLowerBound(currentLtvInWad, ltvBounds.target, ltvBounds.deviation);
        }
        if (currentLtvInWad > ltvBounds.max) {
            revert LtvAboveUpperBound(currentLtvInWad, ltvBounds.target, ltvBounds.deviation);
        }

        // check that there is enough floating amount to deallocate.
        uint256 floatingAmountUnused;
        uint256 floatingAmountCurrent = IERC20(tokenPair.collateralToken).balanceOf(address(this));
        if (!loopModality.allocateFloating()) {
            if (floatingAmountCurrent < allocOrDeallocAmount) {
                revert InsufficientFloatingAmountToDeallocate(floatingAmountCurrent, allocOrDeallocAmount);
            }
            floatingAmountUnused = floatingAmountCurrent - allocOrDeallocAmount;
        } else {
            floatingAmountUnused = floatingAmountCurrent;
        }

        ILenderStaging(lenderModule_).stage(floatingAmountUnused);
    }

    //--------------------------------------------------------
    // Base Looping Strategy Initializer
    //--------------------------------------------------------

    function __BaseLoopingStrategy_init(address lenderModule_) internal virtual {
        BaseLoopingHelperLib.setLenderModule(lenderModule_, true);
    }
}
