// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

/// @dev Role the module requires of a caller before it may initiate a liquidation collateral
///      swap on the caller's behalf.
bytes32 constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");

/// @notice Lifecycle record of one in-flight liquidation (initiate → finalize).
struct Liquidation {
    /// @notice Owner of the Dolomite borrow position (the strategy operator).
    address positionOwner;
    /// @notice Account number of the BTCcx-backed borrow position (position A).
    uint256 accountNumber;
    /// @notice Account number of the temporary RedemptionClaimToken-backed position (position B).
    uint256 tempAccountNumber;
    /// @notice RedemptionClaimToken minted and supplied as position B collateral.
    uint256 redemptionClaimTokenSupplied;
    /// @notice Debt-token amount moved from position A onto position B at initiation.
    uint256 debtMoved;
    /// @notice Collateral (BTCcx) withdrawn from position A and sent to redemption.
    uint256 collateralRedeemed;
    /// @notice Cumulative debt-token repaid into position B across (possibly partial)
    ///         finalization calls. Reaches `debtMoved` (plus accrued interest) once fully
    ///         unwound.
    uint256 debtRepaid;
    /// @notice Cumulative RedemptionClaimToken withdrawn from position B and burned across
    ///         (possibly partial) finalization calls. Reaches `redemptionClaimTokenSupplied`
    ///         once the position is fully unwound, at which point the record is cleared.
    uint256 redemptionClaimTokenWithdrawn;
    /// @notice True from initiation until the temporary position is fully repaid.
    bool active;
}

/// @title  ILiquidationModule
/// @notice Interface for the liquidation module used by `PositionHelperDolomiteAssetCX` to unwind
///         AssetCX collateral that cannot be sold directly through a Dolomite exchange wrapper.
interface ILiquidationModule {
    /**
     * @notice Initiates a liquidation collateral swap on a Dolomite borrow position.
     * @dev Only `LIQUIDATOR_ROLE`. Atomically:
     *      1. mints `debtAmountToLiquidate / collateralRatio` RedemptionClaimToken;
     *      2. supplies it as collateral of a fresh module-owned temporary position and moves
     *         `debtAmountToLiquidate` of the position's debt onto that temporary position
     *         (the debt token never leaves Dolomite);
     *      3. withdraws collateral (BTCcx) worth `debtAmountToLiquidate × (1 + buffer)` from
     *         the borrow position and initiates its redemption via the merchant.
     *      Requires the module to be a Dolomite local operator for `positionOwner`.
     * @param positionOwner          Owner of the Dolomite borrow position.
     * @param accountNumber          Account number of the borrow position.
     * @param debtAmountToLiquidate  Debt-token (e.g. USD1) amount to take over.
     * @param receiver               Address that takes delivery of the redeemed BTCcx in debt token (the
     *                               merchant redemption is recorded against it and settled
     *                               off-chain: BTC → debt-token leg.)
     * @return redemptionId          Id used to finalize this liquidation.
     */
    function initiateLiquidationCollateralSwap(
        address positionOwner,
        uint256 accountNumber,
        uint256 debtAmountToLiquidate,
        address receiver
    ) external returns (uint256 redemptionId);

    /// @notice Full lifecycle record for a liquidation initiated via `initiateLiquidationCollateralSwap`.
    /// @param redemptionId Id returned by `initiateLiquidationCollateralSwap`.
    function getLiquidation(uint256 redemptionId) external view returns (Liquidation memory);

    /// @notice All redemption ids ever opened against `(positionOwner, accountNumber)`,
    ///         active or finalized.
    function getLiquidationIds(address positionOwner, uint256 accountNumber) external view returns (uint256[] memory);
}
