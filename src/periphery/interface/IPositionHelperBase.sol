// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

// ── Shared types ──────────────────────────────────────────────────────────────

/// @dev Scratch-pad for target-vault / position-owner token flows.
///      Avoids multiple local address variables in deposit/redeem helpers.
struct TargetOwnerAmount {
    address target;
    address owner;
    uint256 amount;
    uint256 expected;
}

/// @notice All approvals and roles required for a fully-operational position clone.
/// @dev    Every field must be `true` before calling the corresponding operation.
struct PositionApprovals {
    // ── Generic token approvals (positionOwner → helper) ─────────────────────
    /// @dev Required for `supply`.
    bool collateralTokenApproved;
    /// @dev Required for `withdraw` and `selfLiquidate`.
    ///      For Aave V3: approval on the aToken (lender's collateral position token).
    bool lenderCollateralApproved;
    /// @dev Required for `borrow`.
    ///      For Aave V3: credit delegation on the variable/stable debt token.
    bool lenderDebtDelegated;
    /// @dev Required for `repay`.
    bool borrowTokenApproved;
    // ── Target vault ──────────────────────────────────────────────────────────
    /// @dev Required for `requestRedemptionFromTarget`.
    bool vaultSharesApproved;
    /// @dev Required for `cancelRedemptionRequestFromTarget` and `claimRedemptionFromTarget`.
    bool hasWithdrawalManagerRole;
}

/// @dev Scratch-pad for self-liquidation intermediate values.
///      Avoids stack-too-deep in `executeFlash` without requiring `--via-ir`.
struct SelfLiqState {
    address positionOwner;
    address swapModule;
    uint256 totalOwed;
    uint256 collateralUsed;
    uint256 debtRepaid;
}

/// @dev Internal self-liquidation mode selector (shared so subclasses/interfaces can reference it).
enum _SelfLiqMode {
    DebtAmount,
    TargetLtv
}

// ── Interface ─────────────────────────────────────────────────────────────────

interface IPositionHelperBase {
    // ── Errors ───────────────────────────────────────────────────────────────

    /// @dev `collateralToken` / `borrowToken` are inconsistent with the target vault asset.
    error InconsistentTokensBetweenLenderAndTarget();
    /// @dev `yieldVault` is zero or not a deployed contract.
    error InvalidYieldVault();
    error InvalidFlashModule();
    /// @dev `swapModule` is zero or not a deployed contract.
    error InvalidSwapModule();
    /// @dev maxSlippageInWad is invalid (must be < 1e18).
    error InvalidMaxSlippageInWad();
    /// @dev maxSlippageInWad exceeds the per-position configured maximum.
    error MaxSlippageTooHigh(uint64 provided, uint64 maxAllowed);
    /// @dev A lender operation was called with `amount == 0`.
    error ZeroAmount();
    error ZeroShares();
    /// @dev `selfLiqThrBufferInWad_` was zero during initialization.
    error InvalidSelfLiqThrBufferInWad();
    /// @dev `healthyLtvDeviationInWad_` was zero during initialization.
    error InvalidHealthyLtvDeviationInWad();
    /// @dev `healthyLtvInWad` is zero or ≥ WAD.
    error InvalidHealthyLtvInWad();
    /// @dev The LTV band + buffer do not fit below the lender liquidation threshold.
    ///      Thrown when ltvDev == 0 or selfLiqThreshold (= lenderLiqThr − buffer) ≤ healthyLtv + ltvDev.
    error InvalidLtvRange(
        uint64 healthyLtvInWad, uint64 healthyLtvDeviationInWad, uint64 selfLiqThrBufferInWad, uint64 lenderLiqThrInWad
    );
    /// @dev The token decimals encoded in the clone args do not match the token's metadata.
    error InvalidTokenDecimals();
    error ZeroAddress();
    error InvalidOperatorAddress();

    /// @dev Flash callback invoked by an unregistered caller.
    error OnlyFlashModule(address caller, address expected);
    /// @dev Flash callback requester is not this contract.
    error InvalidFlashRequester(address requester, address expected);
    /// @dev Self-liquidation requested but position carries no debt.
    error NoDebt();
    /// @dev `targetLtvInWad` is at or above the current LTV — nothing to repay.
    error TargetLtvTooHigh();
    /// @dev `maxPermissibleLtv` in retract() exceeds the lender's protocol max LTV.
    error MaxPermissibleLtvExceedsLenderMaxLtv();
    /// @dev Contract borrow-token balance is less than the requested repay amount.
    error InsufficientRepayBalance();
    /// @dev The requested withdrawal would push the position LTV above `maxPermissibleLtv`.
    error WithdrawalWouldBreachMaxPermissibleLtv();
    /// @dev The target vault queue is active (async redemption mode), so atomic redemption is disabled.
    error QueueIsActive();
    /// @dev Swap slippage + flash premium exceeded the lender's liquidation bonus.
    error SelfLiqCostExceedsLiquidatorBonus();
    /// @dev The flash loan module returned false instead of reverting, signalling failure.
    error FlashLoanFailed();
    /// @dev targetLtvInWad in deploy() exceeds the collateral asset's protocol max LTV.
    error TargetLtvExceedsMaxLtv();
    /// @dev After cancellation, the vault still reports requesting shares for the epoch.
    error RedemptionRequestNotCleared(uint256 epochID, uint256 remainingShares);
    /// @dev The sender is not the admin nor the operator, and the ltv condition is not met.
    /// @param sender The address of the sender.
    error NeitherAdminNorOperatorWithinPermissibleLtv(address sender);
    /// @dev The positionOwner has more than one active lender collateral reserve, or the single
    ///      active reserve is not COLLATERAL_TOKEN. This contract's LTV math assumes at most one
    ///      collateral reserve (or none, prior to the first supply).
    error MultipleCollateralReservesDetected();
    /// @dev The positionOwner has more than one active lender debt reserve, or the single active
    ///      reserve is not BORROW_TOKEN. This contract's LTV math assumes at most one debt reserve
    ///      (or none, prior to the first borrow).
    error MultipleDebtReservesDetected();

    // ── Events ───────────────────────────────────────────────────────────────
    // No positionOwner field: each clone is in a 1:1 relationship with its owner,
    // so the emitting contract address already identifies the owner.

    event Supplied(uint256 collateralAmount);
    event Withdrawn(uint256 collateralAmount);
    event Borrowed(uint256 borrowAmount);
    event Repaid(uint256 borrowAmount);
    event DepositedOnTarget(uint256 assetAmount, uint256 sharesReceived, address newOwner);
    event RedemptionRequestedFromTarget(uint256 shares, uint256 amount, address newOwner);
    event RedemptionClaimedFromTarget(uint256 amount);
    event RedemptionRequestCancelled(uint256 epochID);
    event PriorityRedemptionRequested(uint256 epochID);
    event PriorityRedemptionRevoked(uint256 epochID);
    event FundsRescued(address indexed token, address indexed to, uint256 amount);
    event SelfLiquidated(
        uint256 flashAmount,
        uint256 debtRepaid,
        uint256 collateralWithdrawn,
        uint256 collateralReturned,
        uint256 collateralSwapped
    );
    event MaxSelfLiquidationSlippageUpdated(uint64 oldMaxSlippageInWad, uint64 newMaxSlippageInWad);
    event HealthyLtvUpdated(uint64 oldHealthyLtvInWad, uint64 newHealthyLtvInWad);
    event HealthyLtvDeviationUpdated(uint64 oldDeviationInWad, uint64 newDeviationInWad);
    event SelfLiqThrBufferUpdated(uint64 oldBufferInWad, uint64 newBufferInWad);

    // ── Target vault operations ───────────────────────────────────────────────

    // -- Loan Operations --------------------------------------------------------
    function supply(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function borrow(uint256 amount) external;
    function repay(uint256 amount) external;
    function selfLiquidate(uint256 debtAmount, uint64 maxSlippageInWad) external;
    function selfLiquidateToLtv(uint64 targetLtvInWad, uint64 maxSlippageInWad) external;

    // -- Deposit/Redemption Operations ------------------------------------------
    // deposit on target vault
    function depositOnTarget(uint256 amount) external returns (uint256 sharesReceived);
    // request redemption from target vault (might not be atomic)
    function requestRedemptionFromTarget(uint256 shares) external returns (uint256 instantAmount);
    /// @notice Cancel an existing queued redemption request and submit a new one.
    /// @dev `requestIdToCancel` is the epoch ID for ConcreteAsyncVaultImpl.
    ///      Returns `instantAmount > 0` if the vault processed the redemption atomically.
    function updateRedemptionRequestFromTarget(uint256 requestIdToCancel, uint256 newSharesAmount)
        external
        returns (uint256 instantAmount);
    function cancelRedemptionRequestFromTarget(uint256 requestId) external;
    function claimRedemptionFromTarget(uint256[] calldata requestIds) external returns (uint256 amount);

    function requestPriorityRedemptionFromTarget(uint256 requestId) external;
    function revokePriorityRedemptionFromTarget(uint256 requestId) external;

    // ── High-level position flows ─────────────────────────────────────────────

    /// @notice Supply collateral, borrow to `targetLtvInWad`, and deploy borrowed funds into target.
    ///         If targetLtv ≤ post-supply LTV (no additional borrowing capacity), the borrow
    ///         and deposit steps are skipped.
    function deploy(uint256 collateralAmount, uint64 targetLtvInWad) external;

    /// @notice Unwind primitive: pull `repayAmount` borrow tokens from positionOwner, repay debt,
    ///         then withdraw `withdrawalAmount` collateral.  The position LTV after the withdrawal
    ///         must not exceed `maxPermissibleLtv`, which itself must not exceed the lender's
    ///         protocol max LTV.  Either amount can be zero.
    function retract(uint256 repayAmount, uint256 withdrawalAmount, uint64 maxPermissibleLtv) external;

    /// @notice Claim fulfilled redemptions then call retract (claimed amount used as repayAmount).
    function claimAndRetract(uint256[] calldata requestIds, uint256 withdrawalAmount, uint64 maxPermissibleLtv) external;

    /// @notice Atomically redeem vault shares (synchronous path) and call retract.
    /// @dev Only works when the target vault queue is inactive (sync redemption mode).
    ///      Reverts with QueueIsActive if the queue is on.
    function redeemAndRetract(uint256 shares, uint256 withdrawalAmount, uint64 maxPermissibleLtv) external;

    /// @notice Rescue ERC-20 tokens accidentally sent to this contract.
    ///         Funds are sent to msg.sender (the admin). Only callable by POSITION_ADMIN_ROLE.
    function rescueFunds(address token, uint256 amount) external;

    // ── View functions ────────────────────────────────────────────────────────

    /// @notice Account on whose behalf operations are executed.
    ///         Read from clone immutable args — not stored in contract storage.
    function POSITION_OWNER() external pure returns (address);
    function yieldVault() external view returns (address);
    function flashModule() external view returns (address);
    function swapModule() external view returns (address);
    function maxSelfLiquidationSlippageInWad() external view returns (uint64);
    function healthyLtvInWad() external view returns (uint64);
    function healthyLtvDeviationInWad() external view returns (uint64);
    function selfLiqThrBufferInWad() external view returns (uint64);

    // ── Admin configuration ───────────────────────────────────────────────────

    /// @notice Sets the maximum allowed self-liquidation slippage, in WAD.
    function setMaxSelfLiquidationSlippageInWad(uint64 newMaxSlippageInWad) external;
    function setHealthyLtvInWad(uint64 newHealthyLtvInWad) external;
    function setHealthyLtvDeviationInWad(uint64 newDeviationInWad) external;
    function setSelfLiqThrBufferInWad(uint64 newBufferInWad) external;

    /// @notice Returns the complete approval and role status for this clone in a single call.
    ///         All fields must be `true` before invoking the corresponding operations.
    function checkApprovals() external view returns (PositionApprovals memory);

    /// @notice Ideal borrow-token amount to repay in order to withdraw `requiredPrincipalAmount`
    ///         of collateral and land exactly at `targetLtvInWad`.
    ///
    /// @dev Formula: repay = max(0, d − (c − R)·p·targetLtv)
    ///      Returns 0 when the position is already at or below targetLtv after the withdrawal,
    ///      i.e. no repayment is needed.
    ///      Returns the full debt when `requiredPrincipalAmount ≥ collateral`.
    ///
    /// @param requiredPrincipalAmount  Collateral to be withdrawn, in collateral token units.
    /// @param targetLtvInWad           Desired post-operation LTV, in WAD (1e18 = 100%).
    /// @return targetRepayAmount       Borrow tokens to repay, in borrow token units.
    function calculateTargetRepayAmount(uint256 requiredPrincipalAmount, uint64 targetLtvInWad)
        external
        view
        returns (uint256 targetRepayAmount);
}
