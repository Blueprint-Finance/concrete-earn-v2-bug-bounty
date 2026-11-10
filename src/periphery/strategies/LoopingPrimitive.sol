// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

import {LoopingPrimitiveLib} from "../lib/Looping/LoopingPrimitiveLib.sol";
import {LoopModalityLib, LoopModality} from "../lib/Looping/LoopModalityLib.sol";
import {
    ILoopingPrimitive,
    TokenPair,
    FlashLoanParams,
    FlashExecuteData,
    FlashOperationParams
} from "../interface/ILoopingPrimitive.sol";
import {IFlashModule} from "../interface/IFlashModule.sol";
import {LenderOpTraits} from "../traits/LenderTraits.sol";
import {LoopingPrimitiveErrors as LPE} from "../lib/Looping/LoopingPrimitiveErrors.sol";
import {LoopingPrimitiveStorageLib as LPSLib} from "../lib/Looping/LoopingPrimitiveStorageLib.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ISwapModule} from "../interface/ISwapModule.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LoopingPrimitive
 * @notice Abstract contract that implements the core flash loan execution logic for looping strategies.
 * @dev This contract handles the execution of flash loans and the associated operations (supply, borrow, repay, withdraw, swap).
 *      It supports four types of operations: allocate+supply, deallocate+supply, allocate+repay, and deallocate+repay.
 */
abstract contract LoopingPrimitive is ILoopingPrimitive, LenderOpTraits {
    using LoopingPrimitiveLib for FlashLoanParams;
    using LoopModalityLib for LoopModality;
    using SafeERC20 for IERC20;

    //--------------------------------------------------------
    // External Functions
    //--------------------------------------------------------

    /**
     * @notice Executes flash loan operations when called by the flash module.
     * @param flashToken The token being flash borrowed.
     * @param flashAmount The amount being flash borrowed.
     * @param flashPremiumAmount The premium amount to be paid for the flash loan.
     * @param requester The address that requested the flash loan (must be this contract).
     * @param loopModality The loop modality indicating the type of operation.
     * @param data Encoded data containing pairedToken, pairedTokenAmount, and floatingAmount.
     * @return success Always returns true if execution succeeds.
     * @dev This function is called by the flash module during flash loan execution.
     *      Validates that the caller is the flash module and the requester is this contract.
     */
    function executeFlash(
        address flashToken,
        uint256 flashAmount,
        uint256 flashPremiumAmount,
        address requester,
        LoopModality loopModality,
        bytes calldata data
    ) external virtual returns (bool) {
        // 1. get the flash module and swap module
        address flashModule_ = LPSLib.fetch().flashModule;
        // 2. check if the caller is the flash module
        if (msg.sender != flashModule_) revert LPE.InvalidCaller(msg.sender, flashModule_);
        // 3. check requester is this contract
        if (requester != address(this)) revert LPE.InvalidRequester(requester, address(this));
        // 4. decode the data
        (address pairedToken, uint256 pairedTokenAmount, uint256 floatingAmount) =
            abi.decode(data, (address, uint256, uint256));

        _executeFlashOperations(
            FlashOperationParams({
                flashToken: flashToken,
                flashAmount: flashAmount,
                flashPremiumAmount: flashPremiumAmount,
                loopModality: loopModality,
                pairedToken: pairedToken,
                pairedTokenAmount: pairedTokenAmount,
                floatingAmount: floatingAmount
            })
        );

        return true;
    }

    //--------------------------------------------------------
    // Public View Functions
    //--------------------------------------------------------

    /**
     * @notice Returns the address of the flash module.
     * @return The address of the flash module.
     */
    function flashModule() public view returns (address) {
        return LPSLib.fetch().flashModule;
    }

    /**
     * @notice Returns the address of the swap module.
     * @return The address of the swap module.
     */
    function swapModule() public view returns (address) {
        return LPSLib.fetch().swapModule;
    }

    //--------------------------------------------------------
    // Internal Functions
    //--------------------------------------------------------

    /**
     * @notice Executes leverage operations, either plain operations or flash loan-based operations.
     * @param params Flash loan parameters containing position and operation details.
     * @param loopModality The loop modality indicating the type of operation.
     * @param tokenPair The token pair (collateral and borrow tokens).
     * @dev If the operation is plain (no flash loan needed), executes directly.
     *      Otherwise, initiates a flash loan or executes operations directly if flashAmount is zero.
     */
    function _leverage(FlashLoanParams memory params, LoopModality loopModality, TokenPair memory tokenPair)
        internal
        virtual
    {
        address flashModule_ = LPSLib.fetch().flashModule;

        // check if its max withdraw, i.e. if floatingAmount is the entire position
        // get position
        (
            uint256 flashAmount,
            uint256 pairedTokenAmount,
            LoopModality newLoopModality,
            uint256 floatingAmount,
            uint256 collateralDiff,
            uint256 debtDiff
        ) = params.leverageData(flashModule_, tokenPair, loopModality);

        loopModality = newLoopModality;
        bool isSupply = loopModality.loopSupply();

        // update params after external delegate call
        params.floatingAmount = floatingAmount;
        params.updateFlashParamsWithDiffs(isSupply, collateralDiff, debtDiff);

        // now either plain supply, plain repay or flash.
        if (loopModality.plainOperation()) {
            if (isSupply) _supply(tokenPair.collateralToken, floatingAmount);
            else _withdraw(tokenPair.collateralToken, floatingAmount);
            return;
        }

        address flashToken = isSupply ? tokenPair.collateralToken : tokenPair.borrowToken;
        address pairedToken = isSupply ? tokenPair.borrowToken : tokenPair.collateralToken;

        // Guard: if flashAmount is 0, execute operations directly without flash loan
        // This can happen in edge cases where calculations result in zero flash amount
        // but other operations (withdraw, supply, swap) may still be needed
        if (flashAmount == 0) {
            _executeFlashOperations(
                FlashOperationParams({
                    flashToken: flashToken,
                    flashAmount: 0,
                    flashPremiumAmount: 0,
                    loopModality: loopModality,
                    pairedToken: pairedToken,
                    pairedTokenAmount: pairedTokenAmount,
                    floatingAmount: floatingAmount
                })
            );
            return;
        }

        if (!IFlashModule(flashModule_)
                .flash(
                    flashToken, flashAmount, loopModality, abi.encode(pairedToken, pairedTokenAmount, floatingAmount)
                )) revert LPE.FlashLoanFailed();
    }

    /**
     * @notice Executes the flash loan operations based on the operation parameters.
     * @param op Flash operation parameters containing all necessary data for execution.
     * @dev Handles four cases: allocate+supply, deallocate+supply, allocate+repay, deallocate+repay.
     *      If flashAmount is zero, operations are executed directly without a flash loan.
     */
    function _executeFlashOperations(FlashOperationParams memory op) internal virtual {
        address swapModule_ = LPSLib.fetch().swapModule;
        address flashModule_ = LPSLib.fetch().flashModule;

        // There are now four cases:
        // 1. allocate and loop supply
        // 2. deallocate and loop supply
        // 3. allocate and loop repay
        // 4. deallocate and loop repay

        uint256 payBackAmount = op.flashAmount + op.flashPremiumAmount;
        uint256 floatingAmountUnused;
        bool isSupplyLoop = op.loopModality.loopSupply();
        bool isAllocation = op.loopModality.allocateFloating();

        if (isSupplyLoop && isAllocation) {
            _supply(op.flashToken, op.flashAmount + op.floatingAmount);
            _borrow(op.pairedToken, op.pairedTokenAmount);
            IERC20(op.pairedToken).forceApprove(swapModule_, op.pairedTokenAmount);
            uint256 amountOut = ISwapModule(swapModule_)
                .swapExactAmountIn(op.pairedToken, op.flashToken, op.pairedTokenAmount, payBackAmount);
            if (amountOut < payBackAmount) revert LPE.InsufficientSwapOutput(amountOut, payBackAmount);
            floatingAmountUnused = amountOut - payBackAmount;
        } else if (isSupplyLoop && !isAllocation) {
            // Validate floatingAmount <= flashAmount to prevent underflow.
            // Note: This revert should never occur in practice, as floatingAmount and flashAmount are calculated
            // together in _leverageData() using formulas that mathematically ensure floatingAmount <= flashAmount
            // for deallocation operations. This check is defense-in-depth to provide clear error messages.
            if (op.floatingAmount > op.flashAmount) {
                revert LPE.InvalidFloatingAmount(op.floatingAmount, op.flashAmount);
            }
            _supply(op.flashToken, op.flashAmount - op.floatingAmount);
            _borrow(op.pairedToken, op.pairedTokenAmount);
            IERC20(op.pairedToken).forceApprove(swapModule_, op.pairedTokenAmount);
            uint256 amountOut = ISwapModule(swapModule_)
                .swapExactAmountIn(op.pairedToken, op.flashToken, op.pairedTokenAmount, payBackAmount);
            if (amountOut < payBackAmount) revert LPE.InsufficientSwapOutput(amountOut, payBackAmount);
            floatingAmountUnused = amountOut - payBackAmount;
        } else if (!isSupplyLoop && isAllocation) {
            _repay(op.flashToken, op.flashAmount);
            _withdraw(op.pairedToken, op.pairedTokenAmount);
            uint256 maxAmountIn = op.pairedTokenAmount + op.floatingAmount;
            IERC20(op.pairedToken).forceApprove(swapModule_, maxAmountIn);
            uint256 amountIn =
                ISwapModule(swapModule_).swapExactAmountOut(op.pairedToken, op.flashToken, maxAmountIn, payBackAmount);
            floatingAmountUnused = maxAmountIn - amountIn;
        } else {
            // !isSupplyLoop && !isAllocation
            _repay(op.flashToken, op.flashAmount);
            _withdraw(op.pairedToken, op.pairedTokenAmount + op.floatingAmount);
            uint256 maxAmountIn = op.pairedTokenAmount;
            // approve the swap module to pull the max amount in
            IERC20(op.pairedToken).forceApprove(swapModule_, maxAmountIn);
            uint256 amountIn =
                ISwapModule(swapModule_).swapExactAmountOut(op.pairedToken, op.flashToken, maxAmountIn, payBackAmount);
            floatingAmountUnused = maxAmountIn - amountIn;
        }
        // Repay the flash loan, i.e. approve the flash module to pull the pay back amount.
        // Note: If flashAmount is 0, payBackAmount is also 0, so this is a no-op
        IERC20(op.flashToken).forceApprove(flashModule_, payBackAmount);
        // Emit the event
        emit ExecuteFlash(
            op.loopModality,
            op.flashAmount,
            op.flashPremiumAmount,
            op.pairedTokenAmount,
            op.floatingAmount,
            floatingAmountUnused
        );
    }

    //--------------------------------------------------------
    // Internal Admin Functions
    //--------------------------------------------------------

    /**
     * @notice Sets the flash module address.
     * @param flashModule_ The address of the new flash module.
     * @param emitEvent Whether to emit the FlashModuleSet event.
     * @dev Reverts if flashModule_ is the zero address.
     */
    function _setFlashModule(address flashModule_, bool emitEvent) internal virtual {
        if (flashModule_ == address(0)) revert LPE.ZeroFlashModuleAddress();
        address previousFlashModule = LPSLib.fetch().flashModule;
        LPSLib.fetch().flashModule = flashModule_;
        if (emitEvent) emit FlashModuleSet(previousFlashModule, flashModule_);
    }

    /**
     * @notice Sets the swap module address.
     * @param swapModule_ The address of the new swap module.
     * @param emitEvent Whether to emit the SwapModuleSet event.
     * @dev Reverts if swapModule_ is the zero address.
     */
    function _setSwapModule(address swapModule_, bool emitEvent) internal virtual {
        if (swapModule_ == address(0)) revert LPE.ZeroSwapModuleAddress();
        address previousSwapModule = LPSLib.fetch().swapModule;
        LPSLib.fetch().swapModule = swapModule_;
        if (emitEvent) emit SwapModuleSet(previousSwapModule, swapModule_);
    }
}
