// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {LoopModality} from "../lib/Looping/LoopModalityLib.sol";
import {ErrorInfo} from "../lib/ErrorInfoLib.sol";

enum LeverageCondition {
    Disabled,
    AboveUpperLtvBound,
    BelowLowerLtvBound,
    WithinBounds
}

struct TokenPair {
    address collateralToken;
    address borrowToken;
}

struct FlashLoanParams {
    // collateral postiion at lender (in principal token denomination)
    uint256 collateralAmount;
    // debt position at lender
    uint256 debtAmount;
    // amount of principal tokens added to the flash to reduce the flash amount
    uint256 floatingAmount;
    // price of the collateral in the borrow token
    uint256 collateralPriceInRay;
    uint64 targetLtvInWad;
    uint64 maxSlippageInWad;
}

struct FlashExecuteData {
    address flashModule;
    address swapModule;
    address pairedToken;
    uint256 pairedTokenAmount;
    uint256 floatingAmount;
    uint256 payBackAmount;
    bool isSupplyLoop;
    bool isAllocation;
}

struct FlashQuote {
    uint256 depthOfLiquidity;
    uint256 collateralAmount;
    uint256 debtAmount;
    uint64 flashPremiumQuoteInWad;
    bool isMaxWithdraw;
}

struct LeverageData {
    uint256 flashAmount;
    uint256 pairedTokenAmount;
    uint256 floatingAmount;
    uint256 collateralDiff;
    uint256 debtDiff;
    uint256 newEquity;
    uint64 flashPremiumQuoteInWad;
    ErrorInfo errorInfo;
}

struct LenderPosition {
    uint256 collateralAmount;
    uint256 debtAmount;
    uint256 floatingAmount;
    uint256 equity;
    uint256 collateralPriceInRay;
}

struct LtvBounds {
    uint64 target;
    uint64 max;
    uint64 min;
    uint64 deviation;
}

struct NewLtvResult {
    uint64 ltvInWad;
    bool isInvalid;
}

/**
 * @notice Parameters for executing flash loan operations.
 * @param flashToken The token being flash borrowed.
 * @param flashAmount The amount being flash borrowed.
 * @param flashPremiumAmount The premium amount to be paid for the flash loan.
 * @param loopModality The loop modality indicating the type of operation.
 * @param pairedToken The paired token (opposite of flashToken in the token pair).
 * @param pairedTokenAmount The amount of paired token involved in the operation.
 * @param floatingAmount The amount of principal tokens added to reduce the flash amount.
 */
struct FlashOperationParams {
    address flashToken;
    uint256 flashAmount;
    uint256 flashPremiumAmount;
    LoopModality loopModality;
    address pairedToken;
    uint256 pairedTokenAmount;
    uint256 floatingAmount;
}

// TODO: improve this interface
interface ILoopingPrimitive {
    event ExecuteFlash(
        LoopModality loopModality,
        uint256 flashAmount,
        uint256 flashPremiumAmount,
        uint256 pairedTokenAmount,
        uint256 floatingAmount,
        uint256 floatingAmountUnused
    );
    event FlashModuleSet(address previousFlashModule, address newFlashModule);
    event SwapModuleSet(address previousSwapModule, address newSwapModule);

    function executeFlash(
        address token,
        uint256 amountInToken,
        uint256 premiumInToken,
        address requester,
        LoopModality loopModality,
        bytes calldata data
    ) external returns (bool);

    // getters
    function flashModule() external view returns (address);
    function swapModule() external view returns (address);
}
