// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// OpenZeppelin
// ─────────────────────────────────────────────────────────────────────────────
import {IAccessControl} from "@openzeppelin-contracts/access/IAccessControl.sol";
import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Internal
// ─────────────────────────────────────────────────────────────────────────────
import {PositionHelperDolomiteBase} from "./PositionHelperDolomiteBase.sol";
import {PositionHelperBase, IPositionHelperBase, _SelfLiqMode} from "./PositionHelperBase.sol";
import {PositionHelperDolomiteAssetCXStorageLib} from "../lib/PositionHelperDolomiteAssetCXStorageLib.sol";
import {DolomitePositionViewLib} from "../lib/DolomitePositionViewLib.sol";
import {ILiquidationModule, LIQUIDATOR_ROLE} from "../interface/ILiquidationModule.sol";
import {IDolomiteMargin, DolomiteAccount} from "../interface/IDolomiteMargin.sol";
import {ContractIdEncoding} from "../../lib/ContractIdEncoding.sol";
import {WAD, RAY} from "../lib/Constants.sol";

/// @title  PositionHelperDolomiteAssetCX
/// @notice Concrete Dolomite position-helper flavour for AssetCX collateral, whose
///         self-liquidation is delegated entirely to a dedicated `liquidationModule` rather than
///         a Dolomite exchange wrapper or the flash-loan + swap-module path (used when the
///         collateral cannot be sold directly through Dolomite's intrinsic `Sell` action, e.g.
///         isolation-mode / wrapped assets).
///
/// @dev Everything shared with other Dolomite flavours (supply/withdraw/borrow/repay, position
///      views, market-ID resolution, sub-account transfers) lives in `PositionHelperDolomiteBase`.
///      This contract adds: the per-clone `initialize`, the liquidation-module and
///      redemption-claim-token storage, and overrides `_selfLiquidate` so that the inherited
///      `selfLiquidate` entry point routes to `liquidationModule` instead of
///      `PositionHelperBase`'s flash-loan + swap-module flow. `flashModule` and `swapModule`
///      are therefore unused by this flavour. `selfLiquidateToLtv` is disabled for this flavour.
contract PositionHelperDolomiteAssetCX is PositionHelperDolomiteBase {
    using Math for uint256;
    using SafeCast for uint256;

    // ── Events ────────────────────────────────────────────────────────────────

    event LiquidationModuleUpdated(address indexed newLiquidationModule);
    event LiquidatorUpdated(address indexed newLiquidator);

    // ── Errors ────────────────────────────────────────────────────────────────

    /// @notice `selfLiquidateToLtv` is disabled for this flavour — `liquidationModule` takes an
    ///         explicit debt amount, not a target LTV. Use `selfLiquidate` instead.
    error SelfLiquidateToLtvDisabled();

    /// @dev FLAVOUR is a function (not a `constant` like `PositionHelperAaveV3`/`PositionHelperMorpho`
    ///      use) purely for signature symmetry across the Dolomite flavours sharing `PositionHelperDolomiteBase`.
    function FLAVOUR() public pure returns (uint256) {
        return 4; // dolomite asset cx
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
    /// @param liquidationModule_        Liquidation module used to unwind AssetCX collateral. Must be non-zero.
    /// @param liquidator_               Receiver of redeemed collateral passed to `liquidationModule` as the
    ///                                  `initiateLiquidationCollateralSwap` `receiver` argument. Must be non-zero.
    /// @param redemptionClaimToken_     Second collateral type tracked by this position (a
    ///                                  receipt/claim token redeemable against the primary collateral).
    ///                                  Must be non-zero. Its `decimals()` need not equal the borrow
    ///                                  token's — `getCurrentLtvWithLiquidationsInWad` normalizes.
    /// @param redemptionClaimMarketId_  Dolomite market ID for `redemptionClaimToken_`.
    /// @param healthyLtvInWad_          Centre of the desired healthy LTV band, in WAD.
    /// @param healthyLtvDeviationInWad_ Half-width of the healthy LTV band, in WAD. Must be > 0.
    /// @param selfLiqThrBufferInWad_    WAD buffer below liq threshold that triggers self-liq. Must be > 0.
    function initialize(
        address admin_,
        address operator_,
        address yieldVault_,
        address liquidationModule_,
        address liquidator_,
        address redemptionClaimToken_,
        uint256 redemptionClaimMarketId_,
        uint64 healthyLtvInWad_,
        uint64 healthyLtvDeviationInWad_,
        uint64 selfLiqThrBufferInWad_
    ) external initializer {
        if (liquidationModule_ == address(0)) revert MissingLiquidationMechanism();
        if (liquidator_ == address(0)) revert IPositionHelperBase.ZeroAddress();
        if (redemptionClaimToken_ == address(0)) revert IPositionHelperBase.ZeroAddress();

        __PositionHelperBase_init(
            admin_,
            operator_,
            yieldVault_,
            address(0),
            address(0),
            healthyLtvInWad_,
            healthyLtvDeviationInWad_,
            selfLiqThrBufferInWad_
        );
        _ltvRangeIsValid(healthyLtvInWad_, healthyLtvDeviationInWad_, selfLiqThrBufferInWad_);

        PositionHelperDolomiteAssetCXStorageLib.DolomiteAssetCXStorage storage $ =
            PositionHelperDolomiteAssetCXStorageLib.fetch();
        $.liquidationModule = liquidationModule_;
        $.liquidator = liquidator_;
        $.redemptionClaimToken = redemptionClaimToken_;
        $.redemptionClaimMarketId = redemptionClaimMarketId_;
        __PositionHelperDolomiteBase_init();
    }

    // ── Liquidation module ────────────────────────────────────────────────────

    /// @notice Liquidation module used to unwind AssetCX collateral during self-liquidation.
    function liquidationModule() public view returns (address) {
        return PositionHelperDolomiteAssetCXStorageLib.fetch().liquidationModule;
    }

    /// @notice Receiver of redeemed collateral passed to `liquidationModule` as the
    ///         `initiateLiquidationCollateralSwap` `receiver` argument.
    function liquidator() public view returns (address) {
        return PositionHelperDolomiteAssetCXStorageLib.fetch().liquidator;
    }

    /// @notice Update the liquidator address.
    /// @dev Only callable by `POSITION_ADMIN_ROLE`.
    function setLiquidator(address liquidator_) external onlyRole(POSITION_ADMIN_ROLE) {
        if (liquidator_ == address(0)) revert IPositionHelperBase.ZeroAddress();
        PositionHelperDolomiteAssetCXStorageLib.fetch().liquidator = liquidator_;
        emit LiquidatorUpdated(liquidator_);
    }

    /// @notice Whether this helper holds `LIQUIDATOR_ROLE` on `liquidationModule`.
    function hasLiquidatorRole() external view returns (bool) {
        return _hasLiquidatorRole();
    }

    /// @dev Checks whether this helper holds `LIQUIDATOR_ROLE` on `liquidationModule`.
    function _hasLiquidatorRole() internal view returns (bool) {
        return IAccessControl(PositionHelperDolomiteAssetCXStorageLib.fetch().liquidationModule)
            .hasRole(LIQUIDATOR_ROLE, address(this));
    }

    // ── Approval check ────────────────────────────────────────────────────────

    /// @dev Collateral withdrawal is only safe once the helper can also invoke `liquidationModule`
    ///      to unwind AssetCX collateral, so `lenderCollateralApproved` additionally requires
    ///      `LIQUIDATOR_ROLE` on top of the base operator check.
    function _getLenderApprovals()
        internal
        view
        override
        returns (bool lenderCollateralApproved, bool lenderDebtDelegated)
    {
        (lenderCollateralApproved, lenderDebtDelegated) = super._getLenderApprovals();
        // main Collateral approval AND
        // ability to mint the second type of collateral (redemption claim token) which requires the liquidator role.
        lenderCollateralApproved = lenderCollateralApproved && _hasLiquidatorRole();
    }

    // ── Redemption claim token ────────────────────────────────────────────────

    /// @notice Second collateral type tracked by this AssetCX position.
    function redemptionClaimToken() public view returns (address) {
        return PositionHelperDolomiteAssetCXStorageLib.fetch().redemptionClaimToken;
    }

    /// @notice Dolomite market ID for `redemptionClaimToken`.
    function redemptionClaimMarketId() public view returns (uint256) {
        return PositionHelperDolomiteAssetCXStorageLib.fetch().redemptionClaimMarketId;
    }

    // ── Redemption claim position views ───────────────────────────────────────

    /// @dev Redemption claim token amount currently supplied across every active liquidation's
    ///      module-owned temporary position, read directly from DOLOMITE_MARGIN.
    function _getRedemptionClaimCollateralAmount() internal view returns (uint256 amount) {
        address module = PositionHelperDolomiteAssetCXStorageLib.fetch().liquidationModule;
        return DolomitePositionViewLib.sumActiveLiquidationMarketBalances(
            DOLOMITE_MARGIN,
            ILiquidationModule(module),
            POSITION_OWNER(),
            ACCOUNT_NUMBER,
            redemptionClaimMarketId(),
            true
        );
    }

    /// @dev Debt currently owed against every active liquidation's module-owned temporary
    ///      position, read directly from DOLOMITE_MARGIN.
    function _getDebtAmountAgainstClaimToken() internal view returns (uint256 amount) {
        address module = PositionHelperDolomiteAssetCXStorageLib.fetch().liquidationModule;
        return DolomitePositionViewLib.sumActiveLiquidationMarketBalances(
            DOLOMITE_MARGIN, ILiquidationModule(module), POSITION_OWNER(), ACCOUNT_NUMBER, BORROW_MARKET_ID(), false
        );
    }

    /// @notice Position across both collateral types tracked by this AssetCX position.
    /// @return collateralAmount     Primary collateral held at ACCOUNT_NUMBER.
    /// @return debtAmount           Primary debt owed at ACCOUNT_NUMBER.
    /// @return redemptionClaimAmount Redemption claim token supplied across every active
    ///                                liquidation's temporary position.
    /// @return redemptionClaimDebt   Debt owed against every active liquidation's temporary position.
    function getFullAssetCXPosition()
        external
        view
        returns (
            uint256 collateralAmount,
            uint256 debtAmount,
            uint256 redemptionClaimAmount,
            uint256 redemptionClaimDebt
        )
    {
        (collateralAmount, debtAmount) = _getPosition(ACCOUNT_NUMBER);
        redemptionClaimAmount = _getRedemptionClaimCollateralAmount();
        redemptionClaimDebt = _getDebtAmountAgainstClaimToken();
    }

    /// @dev Primary position only — redemption-claim collateral/debt sitting in an in-flight
    ///      liquidation's temporary position are intentionally excluded; see `getFullAssetCXPosition`.
    function getPosition() public view override returns (uint256, uint256) {
        return _getPosition(ACCOUNT_NUMBER);
    }

    /// @dev Primary collateral only — see `getPosition`.
    function getCollateralAmount() public view override returns (uint256) {
        return _getCollateralAmount(ACCOUNT_NUMBER);
    }

    /// @dev Primary debt only — see `getPosition`.
    function getDebtAmount() public view override returns (uint256) {
        return _getDebtAmount(ACCOUNT_NUMBER);
    }

    /// @notice Current LTV including every active liquidation's temporary position, in WAD.
    /// @dev Collateral value = primary collateral (converted via `collateralPriceInBorrowTokensInRay`)
    ///      plus redemption claim tokens supplied, normalized from the claim token's own decimals
    ///      to borrow-token decimals (a RedemptionClaimToken redeems for the same debt token at
    ///      par, but its `decimals()` need not equal the borrow token's — unlike COLLATERAL_TOKEN/
    ///      BORROW_TOKEN, it's an arbitrary address passed into `initialize` with no decimals
    ///      check). Debt value = primary debt plus debt against the redemption claim market —
    ///      both already in borrow-token units, so no further conversion is needed for either leg.
    function getCurrentLtvWithLiquidationsInWad() public view returns (uint64) {
        uint256 collateralAmount = _getCollateralAmount(ACCOUNT_NUMBER);
        uint256 collateralValue = _redemptionClaimValueInBorrowTokens();
        // Skip the oracle call entirely when there is no primary collateral to price.
        if (collateralAmount > 0) {
            collateralValue += collateralAmount.mulDiv(collateralPriceInBorrowTokensInRay(), RAY);
        }
        if (collateralValue == 0) return 0;

        uint256 debtValue = _getDebtAmount(ACCOUNT_NUMBER) + _getDebtAmountAgainstClaimToken();
        return Math.min(debtValue.mulDiv(WAD, collateralValue), type(uint64).max).toUint64();
    }

    /// @dev Redemption claim tokens supplied, scaled from the claim token's own decimals to
    ///      borrow-token decimals so the leg is comparable to the rest of `collateralValue`.
    function _redemptionClaimValueInBorrowTokens() internal view returns (uint256) {
        uint256 amount = _getRedemptionClaimCollateralAmount();
        if (amount == 0) return 0;
        uint8 rcDecimals = IERC20Metadata(redemptionClaimToken()).decimals();
        uint8 borrowDecimals = BORROW_DECIMALS();
        if (rcDecimals == borrowDecimals) return amount;
        if (borrowDecimals > rcDecimals) return amount * 10 ** (borrowDecimals - rcDecimals);
        return amount / 10 ** (rcDecimals - borrowDecimals);
    }

    // ── Self-liquidation override ─────────────────────────────────────────────

    /// @dev Overrides `PositionHelperBase._selfLiquidate` so that the inherited `selfLiquidate`
    ///      entry point delegates to `liquidationModule` instead of the flash-loan + swap-module
    ///      flow. `maxSlippageInWad` is unused — the liquidation module is responsible for its own
    ///      conversion terms. `selfLiquidateToLtv` is disabled — see `SelfLiquidateToLtvDisabled`.
    function _selfLiquidate(_SelfLiqMode mode, uint256 debtAmount, uint64, uint64) internal override {
        if (mode != _SelfLiqMode.DebtAmount) revert SelfLiquidateToLtvDisabled();

        address module = PositionHelperDolomiteAssetCXStorageLib.fetch().liquidationModule;
        if (module == address(0)) revert IPositionHelperBase.InvalidSwapModule();

        uint256 currentDebt = getDebtAmount();
        if (debtAmount > currentDebt) debtAmount = currentDebt;
        if (debtAmount == 0) revert IPositionHelperBase.NoDebt();

        ILiquidationModule(module)
            .initiateLiquidationCollateralSwap(POSITION_OWNER(), ACCOUNT_NUMBER, debtAmount, liquidator());
    }
}
