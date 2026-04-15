// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

/**
 * @title IBaseLoopingStrategy
 * @notice Interface for looping strategies that manage leveraged positions through flash loans
 *         and debt management. Provides functionality for allocation, deallocation, leverage
 *         adjustment, position previewing, and administrative controls with configurable LTV bounds.
 *
 * @author Blueprint Finance
 * @custom:protocol Concrete Earn V2
 * @custom:source on request
 * @custom:audits on request
 * @custom:license AGPL-3.0
 */

// ─────────────────────────────────────────────────────────────────────────────
// Protocol-facing interfaces
// ─────────────────────────────────────────────────────────────────────────────
import {LenderPosition, LeverageData} from "./ILoopingPrimitive.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Internal libraries
// ─────────────────────────────────────────────────────────────────────────────
import {LeverageOperation} from "../lib/Looping/LoopModalityLib.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Structs and Types
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Struct containing preview operation results
/// @param flashAmount Amount to flash loan
/// @param pairedTokenAmount Amount of paired token for the operation
/// @param floatingAmount Floating amount used in the operation
/// @param collateralDiff Change in collateral amount
/// @param debtDiff Change in debt amount
/// @param positionEquityBeforeOperation Equity before the operation (including staged liquidity)
/// @param positionEquityAfterOperation Equity after the operation (including staged liquidity)
/// @param maximumLoss Maximum loss from the operation (negative means gain)
/// @param flashPremiumQuoteInWad Flash premium quote in wad
/// @param operation The type of leverage operation
struct PreviewOperationResult {
    uint256 flashAmount;
    uint256 pairedTokenAmount;
    uint256 floatingAmount;
    uint256 collateralDiff;
    uint256 debtDiff;
    uint256 positionEquityBeforeOperation;
    uint256 positionEquityAfterOperation;
    int256 maximumLoss;
    uint64 flashPremiumQuoteInWad;
    LeverageOperation operation;
}

/// @notice Complete state of a lender module including position and configuration
/// @param collateralToken Address of the collateral token
/// @param borrowToken Address of the borrow token
/// @param collateralAmount Amount of collateral currently supplied
/// @param debtAmount Amount of debt currently borrowed
/// @param collateralBalance Balance of collateral tokens held by the lender module
/// @param currentLtvInWad Current loan-to-value ratio in wad (1e18)
/// @param hasFunds Whether the lender module has any funds (collateral, debt, or balance)
struct LenderModuleState {
    address collateralToken;
    address borrowToken;
    uint256 collateralAmount;
    uint256 debtAmount;
    uint256 collateralBalance;
    uint64 currentLtvInWad;
    bool hasFunds;
}

/// @notice Flags indicating the type and context of a preview operation
/// @param isAllocation Whether the operation is an allocation (true) or deallocation (false)
/// @param isPreview Whether this is a preview call (true) or actual execution (false)
/// @param isUserWithdraw Whether this is a user withdrawal (true) or strategy deallocation (false)
struct PreviewOperationFlags {
    bool isAllocation;
    bool isUserWithdraw;
}

/// @notice Parameters for previewing an operation
/// @param allocOrDeallocAmount Amount to allocate or deallocate
/// @param isAllocation Whether this is an allocation (true) or deallocation (false)
/// @param maxSlippageInWad Maximum acceptable slippage in wad (1e18)
/// @param targetLtvInWad Target loan-to-value ratio in wad (1e18)
struct PreviewOperationParams {
    uint256 allocOrDeallocAmount;
    bool isAllocation;
    uint64 maxSlippageInWad;
    uint64 targetLtvInWad;
}

/// @title IBaseLoopingStrategy
/// @notice Shared interface for looping strategy implementations.
interface IBaseLoopingStrategy {
    // ─────────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Thrown when attempting to rescue the strategy's asset token
    /// @param token The token address that cannot be rescued
    error InvalidAssetForRescue(address token);

    /// @notice Thrown when attempting to deallocate more than available floating amount
    /// @param floatingAmount The available floating amount
    /// @param allocOrDeallocAmount The requested deallocation amount
    error InsufficientFloatingAmountToDeallocate(uint256 floatingAmount, uint256 allocOrDeallocAmount);

    /// @notice Thrown when there is insufficient equity to reach the target LTV
    /// @param equity Current equity in the position
    /// @param targetLtvInWad Target loan-to-value ratio in wad
    error InsufficientEquityToReachTargetLtv(uint256 equity, uint64 targetLtvInWad);

    /// @notice Thrown when the borrow token is invalid (same as collateral or zero address)
    error InvalidBorrowToken();

    /// @notice Thrown when the collateral token does not match the strategy's asset
    error InvalidCollateralToken();

    /// @notice Thrown when current LTV is above the upper bound (target + deviation)
    /// @param currentLtvInWad Current loan-to-value ratio in wad
    /// @param targetLtvInWad Target loan-to-value ratio in wad
    /// @param ltvAdditiveDeviationInWad LTV additive deviation in wad
    error LtvAboveUpperBound(uint64 currentLtvInWad, uint64 targetLtvInWad, uint64 ltvAdditiveDeviationInWad);

    /// @notice Thrown when current LTV is below the lower bound (target - deviation)
    /// @param currentLtvInWad Current loan-to-value ratio in wad
    /// @param targetLtvInWad Target loan-to-value ratio in wad
    /// @param ltvAdditiveDeviationInWad LTV additive deviation in wad
    error LtvBelowLowerBound(uint64 currentLtvInWad, uint64 targetLtvInWad, uint64 ltvAdditiveDeviationInWad);

    /// @notice Thrown when LTV is within acceptable bounds (no adjustment needed)
    /// @param currentLtvInWad Current loan-to-value ratio in wad
    /// @param targetLtvInWad Target loan-to-value ratio in wad
    /// @param ltvAdditiveDeviationInWad LTV additive deviation in wad
    error LtvWithinBounds(uint64 currentLtvInWad, uint64 targetLtvInWad, uint64 ltvAdditiveDeviationInWad);

    /// @notice Thrown when looping is already enabled and enableLooping is called again
    error LoopingAlreadyEnabled();

    /// @notice Thrown when a looping operation is attempted but looping is disabled
    error LoopingIsDisabled();

    /// @notice Thrown when a permissionless leverage adjustment is attempted but adjustments are permissioned
    error PermissionedLtvAdjustment();

    /// @notice Thrown when attempting to change lender module but the previous one still has funds
    /// @param collateralAmount Amount of collateral in the previous lender module
    /// @param debtAmount Amount of debt in the previous lender module
    /// @param collateralBalance Collateral balance in the previous lender module
    error PreviousLenderModuleHasFunds(uint256 collateralAmount, uint256 debtAmount, uint256 collateralBalance);

    /// @notice Thrown when attempting to change lender module but the previous one still has debt
    /// @param debtAmount Amount of debt in the previous lender module
    error LenderModuleHasDebt(uint256 debtAmount);

    /// @notice Thrown when target LTV plus deviation exceeds the lender's maximum LTV
    /// @param targetLtvInWad Target loan-to-value ratio in wad
    /// @param ltvAdditiveDeviationInWad LTV additive deviation in wad
    /// @param maxLtvInWad Maximum allowed LTV in wad from the lender
    error TargetLtvPlusDeviationAboveMaxLtv(
        uint64 targetLtvInWad, uint64 ltvAdditiveDeviationInWad, uint64 maxLtvInWad
    );

    /// @notice Thrown when target LTV minus deviation would be below zero
    /// @param targetLtvInWad Target loan-to-value ratio in wad
    /// @param ltvAdditiveDeviationInWad LTV additive deviation in wad
    error TargetLtvMinusDeviationBelowZeroLtv(uint64 targetLtvInWad, uint64 ltvAdditiveDeviationInWad);

    /// @notice Thrown when flash collateral epsilon is zero
    error ZeroFlashCollateralEpsilon();

    /// @notice Thrown when flash module address is zero
    error ZeroFlashModuleAddress();

    /// @notice Thrown when lender module address is zero
    error ZeroLenderModuleAddress();

    /// @notice Thrown when LTV additive deviation is zero
    error ZeroLtvAdditiveDeviation();

    /// @notice Thrown when max slippage is zero
    error ZeroMaxSlippage();

    /// @notice Thrown when target LTV is zero
    error ZeroTargetLtv();

    /// @notice Thrown when swap module address is zero
    error ZeroSwapModuleAddress();

    // ─────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Emitted when the lender module is set or changed
    /// @param previousLenderModule Address of the previous lender module
    /// @param newLenderModule Address of the new lender module
    event LenderModuleSet(address previousLenderModule, address newLenderModule);

    /// @notice Emitted when looping functionality is disabled
    event LoopingDisabled();

    /// @notice Emitted when looping functionality is enabled
    /// @param targetLtvInWad Target loan-to-value ratio in wad (1e18)
    /// @param ltvAdditiveDeviationInWad LTV additive deviation in wad (1e18)
    /// @param maxSlippageInWad Maximum acceptable slippage in wad (1e18)
    /// @param permissionedLtvAdjustment Whether LTV adjustments require permissions
    /// @param flashCollateralEpsilon Minimum flash collateral amount for operations
    event LoopingEnabled(
        uint64 targetLtvInWad,
        uint64 ltvAdditiveDeviationInWad,
        uint64 maxSlippageInWad,
        bool permissionedLtvAdjustment,
        uint256 flashCollateralEpsilon
    );

    /// @notice Emitted when the maximum slippage is updated
    /// @param maxSlippageInWad New maximum acceptable slippage in wad (1e18)
    event MaxSlippageUpdated(uint64 maxSlippageInWad);

    /// @notice Emitted when the permissioned LTV adjustment setting is updated
    /// @param permissionedLtvAdjustment Whether LTV adjustments now require permissions
    event PermissionedLtvAdjustmentUpdated(bool permissionedLtvAdjustment);

    /// @notice Emitted when target LTV and deviation are updated
    /// @param targetLtvInWad New target loan-to-value ratio in wad (1e18)
    /// @param ltvAdditiveDeviationInWad New LTV additive deviation in wad (1e18)
    event TargetLtvAndDeviationSet(uint64 targetLtvInWad, uint64 ltvAdditiveDeviationInWad);

    // ─────────────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Gets the lender module address
    /// @return Lender module address
    function lenderModule() external view returns (address);

    /// @notice Checks whether the leverage condition requires adjustment
    /// @return True if leverage adjustment is needed, false otherwise
    function checkLeverageCondition() external view returns (bool);

    /// @notice Gets the current loan-to-value ratio of the position
    /// @return Current LTV in wad (1e18)
    function getCurrentLtvInWad() external view returns (uint64);

    /// @notice Gets the target loan-to-value ratio
    /// @return Target LTV in wad (1e18)
    function getTargetLtvInWad() external view returns (uint64);

    /// @notice Gets the LTV additive deviation
    /// @return LTV additive deviation in wad (1e18)
    function getLtvAdditiveDeviationInWad() external view returns (uint64);

    /// @notice Gets the complete lender position information
    /// @return position The lender position including collateral, debt, floating amount, equity, and price
    function getLenderPosition() external view returns (LenderPosition memory);

    /// @notice Checks whether looping functionality is enabled
    /// @return True if looping is enabled, false otherwise
    function loopingIsEnabled() external view returns (bool);

    /// @notice Calculates the maximum amount that can be deallocated
    /// @param targetLtvInWad Target loan-to-value ratio in wad (1e18)
    /// @param maxSlippageInWad Maximum acceptable slippage in wad (1e18)
    /// @return Maximum deallocation amount
    function maxDeallocate(uint64 targetLtvInWad, uint64 maxSlippageInWad) external view returns (uint256);

    /// @notice Previews an allocation or deallocation operation without executing it
    /// @param requestedAmount Amount to allocate or deallocate
    /// @param isAllocation True for allocation, false for deallocation
    /// @param targetLtvInWad Target loan-to-value ratio in wad (1e18)
    /// @param maxSlippageInWad Maximum acceptable slippage in wad (1e18)
    /// @return result Preview operation result containing all operation details
    /// @return ltvUpperBoundReached Whether target LTV exceeds upper bound
    /// @return deallocationHigherThanEquity Whether deallocation exceeds equity
    /// @return insufficientFlashLiquidity Whether flash liquidity is insufficient
    function previewOperation(
        uint256 requestedAmount,
        bool isAllocation,
        uint64 targetLtvInWad,
        uint64 maxSlippageInWad
    )
        external
        view
        returns (
            PreviewOperationResult memory result,
            bool ltvUpperBoundReached,
            bool deallocationHigherThanEquity,
            bool insufficientFlashLiquidity
        );

    // ─────────────────────────────────────────────────────────────────────────────
    // Position Management
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Permissionless adjustment of leverage to target parameters
    /// @dev Can only be called when looping is enabled and LTV adjustments are not permissioned
    function adjustLeverage() external;

    /// @notice Permissioned adjustment of leverage with custom parameters
    /// @param maxSlippageInWad Maximum acceptable slippage in wad (1e18)
    /// @param targetLtvInWad Target loan-to-value ratio in wad (1e18)
    /// @param setNewTargetLtv Whether to update the stored target LTV with the provided value
    function adjustLeverage(uint64 maxSlippageInWad, uint64 targetLtvInWad, bool setNewTargetLtv) external;

    // ─────────────────────────────────────────────────────────────────────────────
    // Administrative Controls
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Disables looping functionality
    /// @dev Removes approvals from the lender module
    function disableLooping() external;

    /// @notice Enables looping functionality with specified parameters
    /// @param flashModule_ Address of the flash loan module
    /// @param swapModule_ Address of the swap module
    /// @param targetLtvInWad Target loan-to-value ratio in wad (1e18)
    /// @param flashCollateralEpsilon Minimum flash collateral amount for operations
    /// @param ltvAdditiveDeviationInWad LTV additive deviation in wad (1e18)
    /// @param maxSlippageInWad Maximum acceptable slippage in wad (1e18)
    /// @param permissionedLtvAdjustment Whether LTV adjustments require permissions
    function enableLooping(
        address flashModule_,
        address swapModule_,
        uint64 targetLtvInWad,
        uint256 flashCollateralEpsilon,
        uint64 ltvAdditiveDeviationInWad,
        uint64 maxSlippageInWad,
        bool permissionedLtvAdjustment
    ) external;

    /// @notice Updates the permissioned LTV adjustment setting
    /// @param permissionedLtvAdjustment_ Whether LTV adjustments should require permissions
    function permissionedLtvAdjustment(bool permissionedLtvAdjustment_) external;

    /// @notice Updates the maximum slippage parameter
    /// @param maxSlippageInWad New maximum acceptable slippage in wad (1e18)
    function setMaxSlippage(uint64 maxSlippageInWad) external;

    /// @notice Updates the target LTV and deviation parameters
    /// @param targetLtvInWad New target loan-to-value ratio in wad (1e18)
    /// @param ltvAdditiveDeviationInWad New LTV additive deviation in wad (1e18)
    function setTargetLtvAndDeviation(uint64 targetLtvInWad, uint64 ltvAdditiveDeviationInWad) external;

    // ─────────────────────────────────────────────────────────────────────────────
    // Module Configuration
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Updates the flash loan module address
    /// @param flashModule_ Address of the new flash loan module
    function setFlashModule(address flashModule_) external;

    /// @notice Updates the lender module address
    /// @param lenderModule_ Address of the new lender module
    /// @dev Validates the new module and removes approvals from the previous one
    function setLenderModule(address lenderModule_) external;

    /// @notice Updates the swap module address
    /// @param swapModule_ Address of the new swap module
    function setSwapModule(address swapModule_) external;

    // ─────────────────────────────────────────────────────────────────────────────
    // Emergency Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Emergency function to rescue tokens that are not the strategy asset
    /// @param token Address of the token to rescue
    /// @param amount Amount of tokens to rescue
    /// @dev Cannot be used to rescue the strategy's asset token
    function rescueFunds(address token, uint256 amount) external;
}
