// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// OpenZeppelin
// ─────────────────────────────────────────────────────────────────────────────
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Internal
// ─────────────────────────────────────────────────────────────────────────────
import {PositionHelperDolomiteBase} from "./PositionHelperDolomiteBase.sol";
import {PositionHelperBase, IPositionHelperBase} from "./PositionHelperBase.sol";
import {PositionManagementHelperLib as PMHLib} from "../lib/PositionManagementHelperLib.sol";
import {PositionHelperDolomiteStorageLib} from "../lib/PositionHelperDolomiteStorageLib.sol";
import {DolomiteAccountActionLib} from "../lib/DolomiteAccountActionLib.sol";
import {ContractIdEncoding} from "../../lib/ContractIdEncoding.sol";
import {RAY, WAD} from "../lib/Constants.sol";

/// @title  PositionHelperDolomiteNative
/// @notice Concrete Dolomite position-helper flavour whose self-liquidation is performed
///         natively on Dolomite: collateral is sold for borrow tokens via a Dolomite-whitelisted
///         exchange wrapper using Dolomite's intrinsic `Sell` action, with no flash loan involved.
///         Falls back to the flash-loan + swap-module path (`PositionHelperBase.selfLiquidate`)
///         when no wrapper is configured.
///
/// @dev Everything shared with other Dolomite flavours (supply/withdraw/borrow/repay, position
///      views, market-ID resolution, sub-account transfers) lives in `PositionHelperDolomiteBase`.
///      This contract adds only: the per-clone `initialize`, the wrapper storage, and the
///      wrapper-based self-liquidation entry points.
///
/// @dev Note: `selfLiquidateDolomiteNative(ToLtv)` needs no additional allowance — the collateral
///      being sold already lives inside DOLOMITE_MARGIN's own balance for the position account;
///      the `Sell` action moves it directly to `dolomiteExchangeWrapper` and back.
contract PositionHelperDolomiteNative is PositionHelperDolomiteBase {
    using Math for uint256;

    // ── Errors ────────────────────────────────────────────────────────────────

    /// @dev Realised proceeds from `_selfLiquidateDolomiteNative`'s Dolomite-native sell fell
    ///      short of `expectedProceeds` (oracle-implied) by more than
    ///      `maxSelfLiquidationSlippageInWad`. Distinct from `IPositionHelperBase.MaxSlippageTooHigh`,
    ///      which validates a *configured* slippage value against its cap rather than a realised
    ///      execution outcome.
    error SlippageTooHigh(uint256 debtRepaid, uint256 minProceeds);

    // ── Events ────────────────────────────────────────────────────────────────

    event DolomiteExchangeWrapperUpdated(address indexed newWrapper);
    /// @dev Emitted by `selfLiquidateDolomiteNative` / `selfLiquidateDolomiteNativeToLtv`.
    event SelfLiquidatedNative(uint256 collateralSold, uint256 debtRepaid);

    /// @dev FLAVOUR is a function (not a `constant` like `PositionHelperAaveV3`/`PositionHelperMorpho`
    ///      use) purely for signature symmetry across the Dolomite flavours sharing `PositionHelperDolomiteBase`.
    function FLAVOUR() public pure returns (uint256) {
        return 3; // dolomite native
    }

    function ID() public pure virtual override(PositionHelperBase) returns (uint64) {
        return ContractIdEncoding.encode(CONTRACT_TYPE, FLAVOUR(), 1, 6, 0);
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param dolomiteMargin_ Address of the DolomiteMargin contract.
    /// @param accountNumber_  Dolomite sub-account number used for all position operations.
    constructor(address dolomiteMargin_, uint256 accountNumber_)
        PositionHelperDolomiteBase(dolomiteMargin_, accountNumber_)
    {
        _disableInitializers();
    }

    // ── Per-clone initializer ─────────────────────────────────────────────────

    /// @notice Initializes a freshly cloned instance. Must be called exactly once.
    ///
    /// @param admin_                    Address granted `POSITION_ADMIN_ROLE`.
    /// @param operator_                 Address granted `POSITION_OPERATOR_ROLE`.
    /// @param yieldVault_               Async ERC4626 vault (asset must equal borrowToken).
    /// @param flashModule_              Flash loan module (IFlashModule). May be zero when
    ///                                  `dolomiteExchangeWrapper_` is provided.
    /// @param swapModule_               Swap module (ISwapModule). May be zero when
    ///                                  `dolomiteExchangeWrapper_` is provided.
    /// @param dolomiteExchangeWrapper_  Dolomite-whitelisted exchange wrapper for native self-liq.
    ///                                  May be zero when `flashModule_` + `swapModule_` are provided.
    ///                                  At least one of (dolomiteExchangeWrapper_, flashModule_)
    ///                                  must be non-zero.
    /// @param healthyLtvInWad_          Centre of the desired healthy LTV band, in WAD.
    /// @param healthyLtvDeviationInWad_ Half-width of the healthy LTV band, in WAD. Must be > 0.
    /// @param selfLiqThrBufferInWad_    WAD buffer below liq threshold that triggers self-liq. Must be > 0.
    function initialize(
        address admin_,
        address operator_,
        address yieldVault_,
        address flashModule_,
        address swapModule_,
        address dolomiteExchangeWrapper_,
        uint64 healthyLtvInWad_,
        uint64 healthyLtvDeviationInWad_,
        uint64 selfLiqThrBufferInWad_
    ) external initializer {
        if (dolomiteExchangeWrapper_ == address(0) && flashModule_ == address(0)) {
            revert MissingLiquidationMechanism();
        }

        __PositionHelperBase_init(
            admin_,
            operator_,
            yieldVault_,
            flashModule_,
            swapModule_,
            healthyLtvInWad_,
            healthyLtvDeviationInWad_,
            selfLiqThrBufferInWad_
        );
        _ltvRangeIsValid(healthyLtvInWad_, healthyLtvDeviationInWad_, selfLiqThrBufferInWad_);

        PositionHelperDolomiteStorageLib.fetch().dolomiteExchangeWrapper = dolomiteExchangeWrapper_;
        __PositionHelperDolomiteBase_init();
    }

    // ── Dolomite-native self-liquidation ─────────────────────────────────────

    /// @notice Current Dolomite exchange wrapper used for native self-liquidation.
    ///         Returns `address(0)` when the flash+swap module path is active instead.
    function dolomiteExchangeWrapper() public view returns (address) {
        return PositionHelperDolomiteStorageLib.fetch().dolomiteExchangeWrapper;
    }

    /// @notice Update the Dolomite exchange wrapper address.
    ///         Set to `address(0)` to fall back to the flash+swap module path
    ///         (requires flashModule and swapModule to be configured).
    /// @dev Only callable by `POSITION_ADMIN_ROLE`.
    function setDolomiteExchangeWrapper(address wrapper_) external onlyRole(POSITION_ADMIN_ROLE) {
        PositionHelperDolomiteStorageLib.fetch().dolomiteExchangeWrapper = wrapper_;
        emit DolomiteExchangeWrapperUpdated(wrapper_);
    }

    /// @notice Dolomite-native self-liquidation: sells collateral for borrow tokens and repays
    ///         debt with the proceeds, targeting `debtAmount` repaid. Same guard/trigger rails as
    ///         `selfLiquidate` — the operator may only call within the self-liq buffer zone below
    ///         the liquidation threshold; admin may always call.
    ///
    /// @dev A single `operate()` call with one `Sell` action on positionOwner's own
    ///      `ACCOUNT_NUMBER` account. No scratch account, no `Liquidate` action, no
    ///      liquidation discount, no flash loan, and — unlike Dolomite's own `Liquidate` action —
    ///      no requirement that the account be ACTUALLY undercollateralized at the protocol level;
    ///      only this contract's own `_requireCanLiquidate` buffer check and
    ///      `_requireSingleCollateralPosition` market guard gate the call.
    ///      Requires `dolomiteExchangeWrapper` to be configured via `setDolomiteExchangeWrapper`.
    ///
    ///      `debtAmount` is converted to a collateral-sell amount using the oracle price; the
    ///      actual proceeds depend on the real swap executed by the wrapper via `swapData`, so
    ///      the realised debt reduction may differ slightly from `debtAmount`.
    ///
    /// @param debtAmount  Borrow-token units to target repaying (must be > 0). Capped to the
    ///                    position's current debt — passing a value at or above the outstanding
    ///                    debt (e.g. padded to guarantee a full close despite interest accrual)
    ///                    closes the position exactly rather than selling excess collateral into
    ///                    a surplus supply balance the slippage check can't see.
    /// @param swapData    Calldata forwarded verbatim to the wrapper's `exchange(...)` function.
    function selfLiquidateDolomiteNative(uint256 debtAmount, bytes calldata swapData) external {
        _requireCanLiquidate();
        _requireSingleCollateralPosition();
        if (debtAmount == 0) revert IPositionHelperBase.NoDebt();
        (address wrapper, uint256 currentDebt, uint256 price) = _loadNativeSelfLiqContext();
        if (debtAmount > currentDebt) debtAmount = currentDebt;
        uint256 collateralAmountToSell = debtAmount.mulDiv(RAY, price, Math.Rounding.Ceil);
        _selfLiquidateDolomiteNative(collateralAmountToSell, price, wrapper, swapData);
    }

    /// @notice Dolomite-native self-liquidation reducing position LTV to `targetLtvInWad`.
    ///         Same guard/trigger rails as `selfLiquidateToLtv`.
    ///
    /// @dev Sizes the collateral to sell via `PMHLib.sellAmountForTargetLtv`, which solves
    ///      for the requested LTV while both collateral and debt fall together (the sale
    ///      funds the repayment). Then executes the same single-`Sell` `operate()` call as
    ///      `selfLiquidateDolomiteNative`.
    ///
    /// @param targetLtvInWad  Desired post-liquidation LTV, in WAD (1e18 = 100%).
    /// @param swapData        Calldata forwarded verbatim to the wrapper's `exchange(...)` function.
    function selfLiquidateDolomiteNativeToLtv(uint64 targetLtvInWad, bytes calldata swapData) external {
        _requireCanLiquidate();
        _requireSingleCollateralPosition();
        (address wrapper, uint256 currentDebt, uint256 price) = _loadNativeSelfLiqContext();
        uint256 collateral = getCollateralAmount();
        uint256 collateralAmountToSell = PMHLib.sellAmountForTargetLtv(price, targetLtvInWad, collateral, currentDebt);
        if (collateralAmountToSell == 0 || collateralAmountToSell == type(uint256).max) {
            revert IPositionHelperBase.TargetLtvTooHigh();
        }
        if (collateralAmountToSell > collateral) collateralAmountToSell = collateral;
        _selfLiquidateDolomiteNative(collateralAmountToSell, price, wrapper, swapData);
    }

    /// @dev Shared preamble for both native self-liquidation entry points: resolves the
    ///      configured wrapper, the position's current debt, and the oracle price, applying the
    ///      guards common to both (`InvalidSwapModule`, `NoDebt`).
    function _loadNativeSelfLiqContext() internal view returns (address wrapper, uint256 currentDebt, uint256 price) {
        wrapper = PositionHelperDolomiteStorageLib.fetch().dolomiteExchangeWrapper;
        if (wrapper == address(0)) revert IPositionHelperBase.InvalidSwapModule();
        currentDebt = getDebtAmount();
        if (currentDebt == 0) revert IPositionHelperBase.NoDebt();
        price = collateralPriceInBorrowTokensInRay();
    }

    /// @dev Executes a Dolomite-native self-liquidation in a single one-action `operate()` call.
    ///
    ///   accounts[0] = (POSITION_OWNER, ACCOUNT_NUMBER) — the only account involved.
    ///
    ///   Action 0 — Sell: sells `collateralAmountToSell` of COLLATERAL_MARKET for BORROW_MARKET
    ///     tokens via `wrapper`, crediting the proceeds directly to the account's BORROW_MARKET
    ///     balance (i.e. repaying debt, since that balance is negative).
    ///     Dolomite enforces solvency for the account AFTER the action completes.
    function _selfLiquidateDolomiteNative(
        uint256 collateralAmountToSell,
        uint256 price,
        address wrapper,
        bytes calldata swapData
    ) internal {
        uint256 expectedProceeds = collateralAmountToSell.mulDiv(price, RAY);
        uint256 debtBefore = getDebtAmount();
        DolomiteAccountActionLib.sell(
            DOLOMITE_MARGIN,
            POSITION_OWNER(),
            ACCOUNT_NUMBER,
            COLLATERAL_MARKET_ID(),
            BORROW_MARKET_ID(),
            collateralAmountToSell,
            wrapper,
            swapData
        );
        uint256 debtRepaid = debtBefore - getDebtAmount();
        uint256 minProceeds = expectedProceeds.mulDiv(WAD - maxSelfLiquidationSlippageInWad(), WAD);
        if (debtRepaid < minProceeds) revert SlippageTooHigh(debtRepaid, minProceeds);

        emit SelfLiquidatedNative(collateralAmountToSell, debtRepaid);
    }
}
